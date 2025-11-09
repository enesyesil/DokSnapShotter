# frozen_string_literal: true

require 'yaml'
require 'ostruct'
require 'rufus-scheduler'

module DokSnap
  class Config
    attr_reader :s3, :encryption, :apps, :status_server

    def initialize(config_path = 'config.yaml')
      @config_path = config_path
      load_config
      validate_config
    end

    private

    def load_config
      unless File.exist?(@config_path)
        raise "Configuration file not found: #{@config_path}"
      end

      raw_config = YAML.safe_load(File.read(@config_path))
      @s3 = parse_s3_config(raw_config['s3'] || {})
      @encryption = parse_encryption_config(raw_config['encryption'] || {})
      @apps = parse_apps_config(raw_config['apps'] || [])
      @status_server = parse_status_server_config(raw_config['status_server'] || {})
    end

    def parse_s3_config(raw)
      bucket = raw['bucket'] || raise('S3 bucket is required')
      
      # Validate bucket name format (AWS S3 rules)
      unless bucket.match?(/\A[a-z0-9][a-z0-9\-\.]*[a-z0-9]\z/) && bucket.length.between?(3, 63)
        raise "Invalid S3 bucket name: #{bucket}. Must be 3-63 characters, lowercase alphanumeric."
      end
      
      OpenStruct.new(
        endpoint: raw['endpoint'] || 's3.amazonaws.com',
        bucket: bucket,
        region: raw['region'] || 'us-east-1',
        access_key_id: ENV['AWS_ACCESS_KEY_ID'] || raise('AWS_ACCESS_KEY_ID environment variable is required'),
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'] || raise('AWS_SECRET_ACCESS_KEY environment variable is required')
      )
    end

    def parse_encryption_config(raw)
      method = raw['method'] || 'gpg'
      
      case method
      when 'gpg'
        public_key = ENV['GPG_PUBLIC_KEY'] || raise('GPG_PUBLIC_KEY environment variable is required for GPG encryption')
        OpenStruct.new(method: 'gpg', public_key: public_key)
      when 'aes256'
        password = ENV['ENCRYPTION_PASSWORD'] || raise('ENCRYPTION_PASSWORD environment variable is required for AES-256 encryption')
        OpenStruct.new(method: 'aes256', password: password)
      else
        raise "Unsupported encryption method: #{method}. Use 'gpg' or 'aes256'"
      end
    end

    def parse_apps_config(raw)
      raw.map do |app_config|
        OpenStruct.new(
          name: app_config['name'] || raise('App name is required'),
          type: app_config['type'] || raise('App type is required (volume or directory)'),
          source: app_config['source'] || raise('App source path is required'),
          schedule: app_config['schedule'] || raise('App schedule is required (cron format)'),
          retention: parse_retention_config(app_config['retention'] || {}),
          hooks: parse_hooks_config(app_config['hooks'] || {})
        )
      end
    end

    def parse_retention_config(raw)
      OpenStruct.new(
        keep_last: raw['keep_last'],
        daily: raw['daily'],
        weekly: raw['weekly'],
        monthly: raw['monthly']
      )
    end

    def parse_hooks_config(raw)
      OpenStruct.new(
        pre_backup: raw['pre_backup'],
        post_backup: raw['post_backup']
      )
    end

    def parse_status_server_config(raw)
      OpenStruct.new(
        enabled: raw.fetch('enabled', true),
        port: raw.fetch('port', 4567),
        bind: raw.fetch('bind', '0.0.0.0'),
        api_key: ENV['DOKSNAP_API_KEY'] || raw['api_key'] || nil,
        require_auth: raw.fetch('require_auth', false)  # Default to false for hobby use
      )
    end

    def validate_config
      validate_apps
      validate_s3_credentials
      validate_encryption_keys
      validate_schedules
      validate_app_names
    end

    def validate_apps
      # Define allowed base directories for security
      ALLOWED_BASE_PATHS = [
        '/var/lib/docker/volumes',
        '/data',
        '/backups',
        '/opt',
        '/srv'
      ].freeze
      
      # Disallowed paths for security
      DISALLOWED_PATHS = [
        '/etc',
        '/root',
        '/home',
        '/usr/bin',
        '/usr/sbin',
        '/bin',
        '/sbin',
        '/proc',
        '/sys',
        '/dev'
      ].freeze

      @apps.each do |app|
        unless %w[volume directory].include?(app.type)
          raise "Invalid app type for #{app.name}: #{app.type}. Must be 'volume' or 'directory'"
        end

        # Normalize and validate path
        begin
          normalized = File.expand_path(app.source)
          real_path = File.realpath(normalized) if File.exist?(normalized)
        rescue => e
          raise "Invalid source path for app #{app.name}: #{app.source} - #{e.message}"
        end

        # Check for path traversal attempts
        if normalized.include?('..') || normalized.include?('//')
          raise "Path traversal detected in source path for app #{app.name}: #{app.source}"
        end

        # Check against disallowed paths
        if DISALLOWED_PATHS.any? { |disallowed| normalized.start_with?(disallowed) }
          raise "Source path for app #{app.name} is in a disallowed directory: #{app.source}"
        end

        # Check if path is under allowed base
        unless ALLOWED_BASE_PATHS.any? { |base| normalized.start_with?(base) }
          raise "Source path for app #{app.name} must be under one of: #{ALLOWED_BASE_PATHS.join(', ')}"
        end

        # Verify path exists
        unless File.exist?(normalized) || Dir.exist?(normalized)
          raise "Source path does not exist for app #{app.name}: #{normalized}"
        end
      end
    end

    def validate_schedules
      @apps.each do |app|
        begin
          # Validate cron format by trying to parse it
          Rufus::Scheduler.parse(app.schedule)
        rescue => e
          raise "Invalid cron schedule for app #{app.name}: #{app.schedule} - #{e.message}"
        end
      end
    end

    def validate_app_names
      @apps.each do |app|
        # App names should only contain safe characters
        unless app.name.match?(/\A[a-zA-Z0-9_\-]+\z/)
          raise "Invalid app name: #{app.name}. Only alphanumeric, underscore, and dash allowed."
        end
      end
      
      # Check for duplicate names
      names = @apps.map(&:name)
      duplicates = names.select { |n| names.count(n) > 1 }.uniq
      unless duplicates.empty?
        raise "Duplicate app names found: #{duplicates.join(', ')}"
      end
    end

    def validate_s3_credentials
      # Credentials are already checked in parse_s3_config
    end

    def validate_encryption_keys
      # Keys are already checked in parse_encryption_config
    end
  end
end
