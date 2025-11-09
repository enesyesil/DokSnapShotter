# frozen_string_literal: true

require 'rufus-scheduler'
require 'thread'
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
      @mutex = Mutex.new  # Thread safety for shared data structures
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
      @mutex.synchronize do
        @running_jobs.dup
      end
    end

    def job_history(limit = 100)
      @mutex.synchronize do
        # Ensure limit doesn't exceed max
        limit = [limit, MAX_JOB_HISTORY].min
        @job_history.last(limit).dup
      end
    end

    private

    def schedule_app(app)
      @scheduler.cron(app.schedule) do
        execute_backup(app)
      end
    end

    def execute_backup(app)
      job_id = "#{app.name}_#{Time.now.to_i}"
      
      # Check if a backup is already running for this app (thread-safe)
      @mutex.synchronize do
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
      end

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
          
          # Clean up local file after successful upload
          begin
            File.delete(backup_file) if File.exist?(backup_file)
          rescue => cleanup_error
            log("Warning: Failed to cleanup backup file #{backup_file}: #{cleanup_error.message}")
          end
          
          # Enforce retention policy
          retention = @retention_manager_factory.call(app)
          retention_result = retention.enforce
          
          log("Retention policy enforced for #{app.name}: deleted #{retention_result[:deleted_count]} old backups")
          
          # Record success (thread-safe)
          @mutex.synchronize do
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
          end
        else
          # Clean up backup file on upload failure
          begin
            File.delete(backup_file) if File.exist?(backup_file)
          rescue => cleanup_error
            log("Warning: Failed to cleanup backup file after upload failure: #{cleanup_error.message}")
          end
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
        
        # Clean up any backup file if it exists (error could occur before backup_file is set)
        # Note: backup.execute handles cleanup of temp files, but we ensure cleanup here too
        begin
          if defined?(backup_file) && backup_file && File.exist?(backup_file)
            File.delete(backup_file)
          end
        rescue => cleanup_error
          log("Warning: Failed to cleanup backup file after error: #{cleanup_error.message}")
        end
        
        # Record failure (thread-safe)
        @mutex.synchronize do
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
        end
      ensure
        # Keep job record for a while, then remove (thread-safe)
        Thread.new do
          sleep 3600 # Keep for 1 hour
          @mutex.synchronize do
            if @running_jobs[app.name] && 
               @running_jobs[app.name][:completed_at] && 
               (Time.now - @running_jobs[app.name][:completed_at]) > 3600
              @running_jobs.delete(app.name)
            end
          end
        end
      end
    end

    def log(message)
      puts "[#{Time.now}] #{message}"
    end
  end
end

