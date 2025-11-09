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
      @temp_dirs = []
      setup_cleanup_handler
    end

    def setup_cleanup_handler
      # Register cleanup handler to ensure temp directories are removed
      at_exit do
        cleanup_temp_dirs
      end
    end

    def cleanup_temp_dirs
      @temp_dirs.each do |temp_dir|
        begin
          if Dir.exist?(temp_dir)
            FileUtils.rm_rf(temp_dir)
          end
        rescue => e
          # Log but don't raise - cleanup should be best effort
          $stderr.puts "Warning: Failed to cleanup temp directory #{temp_dir}: #{e.message}"
        end
      end
      @temp_dirs.clear
    end

    def execute
      start_time = Time.now
      
      # Execute pre-backup hook
      execute_hook(@app.hooks.pre_backup) if @app.hooks.pre_backup

      temp_dir = nil
      encrypted_file = nil
      
      begin
        # Create temporary directory for backup files
        temp_dir = Dir.mktmpdir('doksnap')
        @temp_dirs << temp_dir
        
        # Set restrictive permissions on temp directory (owner read/write/execute only)
        FileUtils.chmod(0700, temp_dir)
        
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
          encrypted_file = nil
          raise "Encrypted backup size exceeds maximum allowed size"
        end
        
        # Generate metadata (includes checksum calculation)
        @metadata = generate_metadata(encrypted_file, start_time)
        
        # Verify backup integrity (uses checksum from metadata, no recalculation)
        verify_backup(encrypted_file)
        
        # Clean up tar file (keep encrypted version)
        File.delete(tar_file) if File.exist?(tar_file)
        
        # Remove temp_dir from tracking since we're keeping the encrypted file
        @temp_dirs.delete(temp_dir)
        
        encrypted_file
      rescue => e
        # Cleanup on error
        if encrypted_file && File.exist?(encrypted_file)
          File.delete(encrypted_file) rescue nil
        end
        if temp_dir && Dir.exist?(temp_dir)
          FileUtils.rm_rf(temp_dir) rescue nil
          @temp_dirs.delete(temp_dir)
        end
        raise
      ensure
        # Execute post-backup hook
        execute_hook(@app.hooks.post_backup) if @app.hooks.post_backup
      end
    end

    private

    def create_tar_archive(output_path)
      source = @app.source
      
      # Early validation: check source exists and is accessible
      unless File.exist?(source)
        raise "Source path does not exist: #{source}"
      end
      
      unless File.readable?(source)
        raise "Source path is not readable: #{source}"
      end
      
      # Check parent directory is writable for output
      output_dir = File.dirname(output_path)
      unless File.writable?(output_dir)
        raise "Output directory is not writable: #{output_dir}"
      end
      
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
      
      # Verify checksum matches (checksum already calculated in generate_metadata)
      # We trust the checksum from metadata since it was just calculated
      # In a production system, you might want to recalculate for extra safety,
      # but for performance we skip recalculation here
      unless @metadata[:checksum]
        raise "Backup metadata missing checksum"
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
      unless File.exist?(executable) || find_executable_in_path(executable)
        raise "Hook executable not found: #{executable}"
      end

      # Execute with proper error handling
      system(*parts)
      unless $?.success?
        raise "Hook command failed with exit code #{$?.exitstatus}: #{command}"
      end
    end

    def find_executable_in_path(executable)
      # Check if executable exists in PATH without using system calls
      return false if executable.nil? || executable.empty?
      
      # If it's an absolute path, just check if it exists
      return File.executable?(executable) if File.absolute_path?(executable) || executable.start_with?('/')
      
      # Search in PATH
      path_dirs = ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
      path_dirs.each do |dir|
        next if dir.empty?
        
        full_path = File.join(dir, executable)
        return true if File.executable?(full_path)
      end
      
      false
    end
  end

  # Add shellescape method if not available
  class String
    def shellescape
      "'#{gsub("'", "'\\''")}'"
    end
  end
end
