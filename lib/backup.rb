# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'time'
require 'tempfile'
require 'shellwords'
require_relative 'encryption'

module DokSnap
  class Backup
    MAX_BACKUP_SIZE = 100 * 1024 * 1024 * 1024 # 100GB limit
    
    attr_reader :app, :metadata

    def initialize(app, encryption)
      @app = app
      @encryption = encryption
      @metadata = {}
    end

    def execute
      start_time = Time.now
      
      # Execute pre-backup hook
      execute_hook(@app.hooks.pre_backup) if @app.hooks.pre_backup

      begin
        # Create temporary directory for backup files
        temp_dir = Dir.mktmpdir('doksnap')
        
        # Generate backup filename
        timestamp = Time.now.utc.strftime('%Y%m%d_%H%M%S')
        base_name = "#{@app.name}_#{timestamp}"
        tar_file = File.join(temp_dir, "#{base_name}.tar.gz")
        encrypted_file = File.join(temp_dir, "#{base_name}.tar.gz.#{@encryption.method == 'gpg' ? 'gpg' : 'enc'}")

        # Create tar archive
        create_tar_archive(tar_file)
        
        # Check file size before encryption
        tar_size = File.size(tar_file)
        if tar_size > MAX_BACKUP_SIZE
          File.delete(tar_file) if File.exist?(tar_file)
          raise "Backup size (#{tar_size / 1_048_576}MB) exceeds maximum allowed size (#{MAX_BACKUP_SIZE / 1_048_576}MB)"
        end
        
        # Encrypt the archive
        @encryption.encrypt(tar_file, encrypted_file)
        
        # Check encrypted file size
        encrypted_size = File.size(encrypted_file)
        if encrypted_size > MAX_BACKUP_SIZE * 1.1 # Allow 10% overhead for encryption
          File.delete(encrypted_file) if File.exist?(encrypted_file)
          raise "Encrypted backup size exceeds maximum allowed size"
        end
        
        # Generate metadata
        @metadata = generate_metadata(encrypted_file, start_time)
        
        # Verify backup integrity
        verify_backup(encrypted_file)
        
        # Clean up tar file (keep encrypted version)
        File.delete(tar_file) if File.exist?(tar_file)
        
        encrypted_file
      ensure
        # Execute post-backup hook
        execute_hook(@app.hooks.post_backup) if @app.hooks.post_backup
      end
    end

    private

    def create_tar_archive(output_path)
      source = @app.source
      
      # Create tar.gz archive
      case @app.type
      when 'volume', 'directory'
        # Use tar command for better compatibility
        cmd = "tar -czf #{output_path.shellescape} -C #{File.dirname(source).shellescape} #{File.basename(source).shellescape} 2>&1"
        result = `#{cmd}`
        
        unless $?.success?
          raise "Failed to create tar archive: #{result}"
        end
      else
        raise "Unsupported app type: #{@app.type}"
      end
    end

    def generate_metadata(file_path, start_time)
      file_size = File.size(file_path)
      checksum = calculate_checksum(file_path)
      end_time = Time.now
      duration = (end_time - start_time).round(2)

      {
        app_name: @app.name,
        timestamp: Time.now.utc.iso8601,
        filename: File.basename(file_path),
        size: file_size,
        size_mb: (file_size / 1_048_576.0).round(2),
        checksum: checksum,
        duration_seconds: duration,
        encryption_method: @encryption.method,
        source_type: @app.type
        # Removed: source_path to prevent information disclosure
      }
    end

    def calculate_checksum(file_path)
      sha256 = Digest::SHA256.new
      File.open(file_path, 'rb') do |f|
        while chunk = f.read(8192)
          sha256.update(chunk)
        end
      end
      sha256.hexdigest
    end

    def verify_backup(file_path)
      # Verify file exists and is readable
      unless File.exist?(file_path) && File.readable?(file_path)
        raise "Backup file is not accessible: #{file_path}"
      end
      
      # Verify file is not empty
      if File.size(file_path) == 0
        raise "Backup file is empty: #{file_path}"
      end
      
      # Verify checksum matches
      calculated_checksum = calculate_checksum(file_path)
      if @metadata[:checksum] && calculated_checksum != @metadata[:checksum]
        raise "Backup checksum verification failed"
      end
      
      true
    end

    def execute_hook(command)
      return unless command && !command.strip.empty?

      # Validate command - only allow safe characters
      unless command.match?(/\A[a-zA-Z0-9_\/\s\.\-\:\"\'=]+\z/)
        raise "Invalid hook command format: contains unsafe characters"
      end
      
      # Additional safety: prevent dangerous commands
      dangerous = ['rm -rf', 'mkfs', 'dd if=', '> /dev/', '$(', '`', ';', '&&', '||', '|']
      if dangerous.any? { |d| command.include?(d) }
        raise "Hook command contains potentially dangerous operations"
      end

      # Use shellsplit to properly parse command
      parts = Shellwords.shellsplit(command)
      
      # First part must be an executable
      executable = parts[0]
      unless File.exist?(executable) || system("which #{executable.shellescape} > /dev/null 2>&1")
        raise "Hook executable not found: #{executable}"
      end

      # Execute with proper error handling
      system(*parts)
      unless $?.success?
        raise "Hook command failed with exit code #{$?.exitstatus}: #{command}"
      end
    end
  end

  # Add shellescape method if not available
  class String
    def shellescape
      "'#{gsub("'", "'\\''")}'"
    end
  end
end
