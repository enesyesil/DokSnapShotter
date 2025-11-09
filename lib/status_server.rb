# frozen_string_literal: true

require 'sinatra/base'
require 'json'

module DokSnap
  class StatusServer < Sinatra::Base
    set :bind, '0.0.0.0'
    set :port, 4567

    def self.set_dependencies(scheduler, s3_uploader, apps, config)
      @@scheduler = scheduler
      @@s3_uploader = s3_uploader
      @@apps = apps
      @@config = config
    end

    # Authentication middleware
    before do
      if @@config.status_server.require_auth
        api_key = request.env['HTTP_X_API_KEY'] || params['api_key']
        expected_key = @@config.status_server.api_key
        
        unless expected_key && api_key == expected_key
          halt 401, { error: 'Unauthorized. Provide X-API-Key header or api_key parameter.' }.to_json
        end
      end
    end

    # Rate limiting (simple in-memory)
    @@rate_limit = {}
    before do
      if @@config.status_server.require_auth
        client_ip = request.ip
        now = Time.now.to_i
        
        # Clean old entries
        @@rate_limit.delete_if { |_, data| data[:time] < now - 60 }
        
        # Check rate limit (60 requests per minute per IP)
        if @@rate_limit[client_ip]
          if @@rate_limit[client_ip][:count] >= 60
            halt 429, { error: 'Rate limit exceeded. Max 60 requests per minute.' }.to_json
          end
          @@rate_limit[client_ip][:count] += 1
        else
          @@rate_limit[client_ip] = { count: 1, time: now }
        end
      end
    end

    # Security headers
    after do
      headers 'X-Content-Type-Options' => 'nosniff'
      headers 'X-Frame-Options' => 'DENY'
      headers 'X-XSS-Protection' => '1; mode=block'
      headers 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains' if request.scheme == 'https'
    end

    get '/health' do
      content_type :json
      { status: 'healthy', timestamp: Time.now.utc.iso8601 }.to_json
    end

    get '/status' do
      content_type :json
      
      status = @@apps.map do |app|
        running_job = @@scheduler.running_jobs[app.name]
        last_backup = get_last_backup(app.name)
        
        {
          app_name: app.name,
          running: !running_job.nil? && running_job[:status] == 'running',
          last_backup: sanitize_backup_info(last_backup),
          next_schedule: app.schedule
        }
      end
      
      { apps: status, timestamp: Time.now.utc.iso8601 }.to_json
    end

    get '/metrics' do
      content_type :json
      
      metrics = {
        apps: @@apps.map do |app|
          backups = @@s3_uploader.list_backups(app.name)
          running_job = @@scheduler.running_jobs[app.name]
          history = @@scheduler.job_history.select { |j| j[:app_name] == app.name }
          
          total_size = backups.sum { |b| b[:size] }
          successful_backups = history.count { |j| j[:status] == 'success' }
          failed_backups = history.count { |j| j[:status] == 'failed' }
          avg_duration = calculate_avg_duration(history)
          
          {
            app_name: app.name,
            total_backups: backups.length,
            total_size_bytes: total_size,
            total_size_mb: (total_size / 1_048_576.0).round(2),
            successful_backups: successful_backups,
            failed_backups: failed_backups,
            success_rate: history.empty? ? 0 : (successful_backups.to_f / history.length * 100).round(2),
            avg_duration_seconds: avg_duration,
            currently_running: !running_job.nil? && running_job[:status] == 'running',
            last_backup_time: backups.first ? backups.first[:last_modified].iso8601 : nil
          }
        end,
        timestamp: Time.now.utc.iso8601
      }
      
      metrics.to_json
    end

    get '/history' do
      content_type :json
      
      app_name = sanitize_app_name(params['app'])
      
      if app_name
        history = @@scheduler.job_history.select { |j| j[:app_name] == app_name }
        # Sanitize history to remove sensitive data
        sanitized_history = history.map { |h| sanitize_history_entry(h) }
        { app: app_name, history: sanitized_history }.to_json
      else
        history_by_app = @@apps.each_with_object({}) do |app, hash|
          history = @@scheduler.job_history.select { |j| j[:app_name] == app.name }
          hash[app.name] = history.map { |h| sanitize_history_entry(h) }
        end
        { history: history_by_app }.to_json
      end
    end

    get '/backups/:app' do
      content_type :json
      
      app_name = sanitize_app_name(params['app'])
      backups = @@s3_uploader.list_backups(app_name)
      
      backups.map do |backup|
        {
          key: backup[:key],
          size: backup[:size],
          size_mb: (backup[:size] / 1_048_576.0).round(2),
          last_modified: backup[:last_modified].iso8601
          # Removed metadata to prevent information disclosure
        }
      end.to_json
    end

    private

    def sanitize_app_name(name)
      return nil unless name
      # Only allow alphanumeric, dash, underscore
      name.match?(/\A[a-zA-Z0-9_\-]+\z/) ? name : nil
    end

    def sanitize_backup_info(backup_info)
      return nil unless backup_info
      {
        timestamp: backup_info[:timestamp],
        size_mb: backup_info[:size_mb],
        duration_seconds: backup_info[:duration_seconds]
        # Removed s3_key to prevent information disclosure
      }
    end

    def sanitize_history_entry(entry)
      {
        job_id: entry[:job_id],
        app_name: entry[:app_name],
        started_at: entry[:started_at]&.iso8601,
        completed_at: entry[:completed_at]&.iso8601,
        status: entry[:status],
        # Only include safe metadata
        size_mb: entry[:metadata]&.dig(:size_mb),
        duration_seconds: entry[:metadata]&.dig(:duration_seconds)
        # Removed: s3_key, source_path, error messages
      }
    end

    def get_last_backup(app_name)
      history = @@scheduler.job_history.select { |j| j[:app_name] == app_name && j[:status] == 'success' }
      return nil if history.empty?
      
      last = history.max_by { |j| j[:completed_at] }
      {
        timestamp: last[:completed_at].iso8601,
        size_mb: last[:metadata][:size_mb],
        duration_seconds: last[:metadata][:duration_seconds]
        # Removed s3_key
      }
    end

    def calculate_avg_duration(history)
      successful = history.select { |j| j[:status] == 'success' && j[:metadata] && j[:metadata][:duration_seconds] }
      return 0 if successful.empty?
      
      durations = successful.map { |j| j[:metadata][:duration_seconds] }
      (durations.sum.to_f / durations.length).round(2)
    end
  end
end
