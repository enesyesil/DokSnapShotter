# frozen_string_literal: true

require 'rufus-scheduler'
require_relative 'backup'

module DokSnap
  class Scheduler
    MAX_JOB_HISTORY = 1000
    
    def initialize(apps, encryption, s3_uploader, retention_manager_factory)
      @apps = apps
      @encryption = encryption
      @s3_uploader = s3_uploader
      @retention_manager_factory = retention_manager_factory
      @scheduler = Rufus::Scheduler.new
      @running_jobs = {}
      @job_history = []
    end

    def start
      @apps.each do |app|
        schedule_app(app)
      end
      
      @scheduler.join
    end

    def stop
      @scheduler.shutdown(:wait)
    end

    def running_jobs
      @running_jobs.dup
    end

    def job_history(limit = 100)
      # Ensure limit doesn't exceed max
      limit = [limit, MAX_JOB_HISTORY].min
      @job_history.last(limit)
    end

    private

    def schedule_app(app)
      @scheduler.cron(app.schedule) do
        execute_backup(app)
      end
    end

    def execute_backup(app)
      job_id = "#{app.name}_#{Time.now.to_i}"
      
      # Check if a backup is already running for this app
      if @running_jobs[app.name]
        log("Skipping backup for #{app.name}: previous backup still running")
        return
      end

      @running_jobs[app.name] = {
        job_id: job_id,
        app_name: app.name,
        started_at: Time.now,
        status: 'running'
      }

      begin
        log("Starting backup for #{app.name}")
        
        # Create backup executor
        backup = Backup.new(app, @encryption)
        
        # Execute backup
        backup_file = backup.execute
        metadata = backup.metadata
        
        # Upload to S3
        upload_result = @s3_uploader.upload(backup_file, metadata)
        
        if upload_result[:success]
          log("Backup uploaded successfully for #{app.name}: #{upload_result[:key]}")
          
          # Clean up local file
          File.delete(backup_file) if File.exist?(backup_file)
          
          # Enforce retention policy
          retention = @retention_manager_factory.call(app)
          retention_result = retention.enforce
          
          log("Retention policy enforced for #{app.name}: deleted #{retention_result[:deleted_count]} old backups")
          
          # Record success
          job_record = {
            job_id: job_id,
            app_name: app.name,
            started_at: @running_jobs[app.name][:started_at],
            completed_at: Time.now,
            status: 'success',
            metadata: metadata,
            s3_key: upload_result[:key],
            retention_deleted: retention_result[:deleted_count]
          }
          
          @job_history << job_record
          
          # Trim history if it gets too large
          if @job_history.length > MAX_JOB_HISTORY
            @job_history = @job_history.last(MAX_JOB_HISTORY)
          end
          
          @running_jobs[app.name][:status] = 'success'
          @running_jobs[app.name][:completed_at] = Time.now
          @running_jobs[app.name][:metadata] = metadata
        else
          raise "Upload failed: #{upload_result[:error]}"
        end
      rescue => e
        # Log error without exposing full backtrace in production
        error_msg = e.message
        if ENV['DEBUG']
          log("Backup failed for #{app.name}: #{error_msg}")
          log(e.backtrace.join("\n"))
        else
          log("Backup failed for #{app.name}: #{error_msg}")
        end
        
        job_record = {
          job_id: job_id,
          app_name: app.name,
          started_at: @running_jobs[app.name][:started_at],
          completed_at: Time.now,
          status: 'failed',
          error: error_msg
          # Don't include full backtrace
        }
        
        @job_history << job_record
        
        # Trim history if it gets too large
        if @job_history.length > MAX_JOB_HISTORY
          @job_history = @job_history.last(MAX_JOB_HISTORY)
        end
        
        @running_jobs[app.name][:status] = 'failed'
        @running_jobs[app.name][:error] = error_msg
        @running_jobs[app.name][:completed_at] = Time.now
      ensure
        # Keep job record for a while, then remove
        Thread.new do
          sleep 3600 # Keep for 1 hour
          @running_jobs.delete(app.name) if @running_jobs[app.name] && 
            @running_jobs[app.name][:completed_at] && 
            (Time.now - @running_jobs[app.name][:completed_at]) > 3600
        end
      end
    end

    def log(message)
      puts "[#{Time.now}] #{message}"
    end
  end
end

