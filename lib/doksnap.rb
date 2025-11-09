# frozen_string_literal: true

require_relative 'config'
require_relative 'encryption'
require_relative 's3_uploader'
require_relative 'retention'
require_relative 'scheduler'
require_relative 'status_server'
require 'sinatra/base'

module DokSnap
  class Application
    def initialize(config_path = 'config.yaml')
      @config = Config.new(config_path)
      @encryption = create_encryption
      @s3_uploader = S3Uploader.new(@config.s3)
      @scheduler = create_scheduler
      @status_server = nil
    end

    def start
      puts "Starting DokSnapShotter backup daemon..."
      puts "Loaded #{@config.apps.length} app(s) for backup"
      
      # Check file descriptor limits
      check_file_descriptor_limits
      
      # Start status server if enabled
      if @config.status_server.enabled
        start_status_server
      end
      
      # Setup signal handlers
      setup_signal_handlers
      
      # Start scheduler (this will block)
      @scheduler.start
    end

    def stop
      puts "\nShutting down DokSnapShotter..."
      @scheduler.stop
      @status_server&.quit
      puts "Shutdown complete"
    end

    private

    def create_encryption
      case @config.encryption.method
      when 'gpg'
        Encryption.new(
          method: 'gpg',
          public_key: @config.encryption.public_key,
          key_id: @config.encryption.key_id
        )
      when 'aes256'
        Encryption.new(
          method: 'aes256',
          password: @config.encryption.password
        )
      else
        raise "Unsupported encryption method: #{@config.encryption.method}"
      end
    end

    def create_scheduler
      retention_factory = lambda do |app|
        Retention.new(@s3_uploader, app, app.retention)
      end
      
      Scheduler.new(
        @config.apps,
        @encryption,
        @s3_uploader,
        retention_factory
      )
    end

    def start_status_server
      StatusServer.set :bind, @config.status_server.bind
      StatusServer.set :port, @config.status_server.port
      StatusServer.set_dependencies(@scheduler, @s3_uploader, @config.apps, @config)
      
      @status_server = Thread.new do
        StatusServer.run!
      end
      
      puts "Status server started on http://#{@config.status_server.bind}:#{@config.status_server.port}"
      if @config.status_server.require_auth
        puts "Status server authentication enabled (set DOKSNAP_API_KEY environment variable)"
      else
        puts "Status server authentication disabled (enable with require_auth: true for production)"
      end
    end

    def setup_signal_handlers
      Signal.trap('INT') do
        stop
        exit 0
      end
      
      Signal.trap('TERM') do
        stop
        exit 0
      end
    end

    def check_file_descriptor_limits
      begin
        # Get current soft and hard limits
        soft_limit, hard_limit = Process.getrlimit(Process::RLIMIT_NOFILE)
        
        # Warn if soft limit is too low (less than 1024)
        if soft_limit < 1024
          $stderr.puts "Warning: File descriptor soft limit is #{soft_limit} (recommended: >= 1024)"
          $stderr.puts "Consider increasing with: ulimit -n 1024"
        end
        
        # Warn if approaching hard limit (within 20%)
        if soft_limit < hard_limit * 0.8
          $stderr.puts "Warning: File descriptor soft limit (#{soft_limit}) is less than 80% of hard limit (#{hard_limit})"
        end
      rescue => e
        # Silently fail on systems where this isn't supported
        # (e.g., Windows or systems without getrlimit)
      end
    end
  end
end

