# frozen_string_literal: true

require 'aws-sdk-s3'

module DokSnap
  class S3Uploader
    def initialize(s3_config)
      @s3_config = s3_config
      @client = create_s3_client
    end

    def upload(file_path, metadata)
      key = generate_s3_key(metadata)
      
      # Use multipart upload for files larger than 100MB
      if File.size(file_path) > 100 * 1_048_576
        multipart_upload(file_path, key, metadata)
      else
        simple_upload(file_path, key, metadata)
      end
    end

    def list_backups(app_name)
      prefix = "backups/#{app_name}/"
      objects = []
      
      @client.list_objects_v2(
        bucket: @s3_config.bucket,
        prefix: prefix
      ).each do |response|
        objects.concat(response.contents.map do |obj|
          {
            key: obj.key,
            size: obj.size,
            last_modified: obj.last_modified,
            metadata: get_object_metadata(obj.key)
          }
        end)
      end
      
      objects.sort_by { |o| o[:last_modified] }.reverse
    end

    def delete_backup(key)
      @client.delete_object(
        bucket: @s3_config.bucket,
        key: key
      )
    end

    def get_object_metadata(key)
      begin
        response = @client.head_object(
          bucket: @s3_config.bucket,
          key: key
        )
        response.metadata || {}
      rescue Aws::S3::Errors::NotFound
        {}
      end
    end

    private

    def create_s3_client
      # Configure timeouts and retry logic
      Aws::S3::Client.new(
        access_key_id: @s3_config.access_key_id,
        secret_access_key: @s3_config.secret_access_key,
        region: @s3_config.region,
        endpoint: @s3_config.endpoint == 's3.amazonaws.com' ? nil : "https://#{@s3_config.endpoint}",
        force_path_style: @s3_config.endpoint != 's3.amazonaws.com', # Path-style for custom endpoints
        http_open_timeout: 30,  # 30 seconds to establish connection
        http_read_timeout: 300,  # 5 minutes to read response (for large uploads)
        retry_limit: 3,  # Retry up to 3 times
        retry_backoff: lambda { |c| sleep(2 ** c.retries) }  # Exponential backoff
      )
    end

    def generate_s3_key(metadata)
      app_name = metadata[:app_name]
      
      # Sanitize app_name to prevent S3 key manipulation
      # Only allow alphanumeric, dash, underscore for S3 key safety
      sanitized_app_name = app_name.to_s.gsub(/[^a-zA-Z0-9_\-]/, '_')
      
      # Validate app_name format (should already be validated in config, but double-check)
      unless sanitized_app_name.match?(/\A[a-zA-Z0-9_\-]+\z/)
        raise "Invalid app_name format for S3 key generation: #{app_name}"
      end
      
      timestamp = metadata[:timestamp].gsub(/[:\-]/, '').gsub(/T/, '_').split('.').first
      filename = metadata[:filename].gsub(/[^a-zA-Z0-9_\-\.]/, '_')  # Sanitize filename too
      
      "backups/#{sanitized_app_name}/#{timestamp}_#{filename}"
    end

    def simple_upload(file_path, key, metadata)
      File.open(file_path, 'rb') do |file|
        @client.put_object(
          bucket: @s3_config.bucket,
          key: key,
          body: file,
          metadata: {
            'app-name' => metadata[:app_name],
            'timestamp' => metadata[:timestamp],
            'size' => metadata[:size].to_s,
            'checksum' => metadata[:checksum],
            'encryption-method' => metadata[:encryption_method],
            'source-type' => metadata[:source_type]
          },
          server_side_encryption: 'AES256'
        )
      end
      
      { key: key, success: true }
    rescue => e
      { key: key, success: false, error: e.message }
    end

    def multipart_upload(file_path, key, metadata)
      upload_id = nil
      
      begin
        upload_id = @client.create_multipart_upload(
          bucket: @s3_config.bucket,
          key: key,
          metadata: {
            'app-name' => metadata[:app_name],
            'timestamp' => metadata[:timestamp],
            'size' => metadata[:size].to_s,
            'checksum' => metadata[:checksum],
            'encryption-method' => metadata[:encryption_method],
            'source-type' => metadata[:source_type]
          },
          server_side_encryption: 'AES256'
        ).upload_id

        parts = []
        part_number = 1
        chunk_size = 100 * 1_048_576 # 100MB chunks

        begin
          File.open(file_path, 'rb') do |file|
            while chunk = file.read(chunk_size)
              break if chunk.nil? || chunk.empty?
              
              part = @client.upload_part(
                bucket: @s3_config.bucket,
                key: key,
                part_number: part_number,
                upload_id: upload_id,
                body: chunk
              )
              
              parts << { etag: part.etag, part_number: part_number }
              part_number += 1
            end
          end
        rescue => e
          # File reading or upload_part failed - abort multipart upload
          abort_multipart_upload(upload_id, key) if upload_id
          raise "Multipart upload failed during file reading: #{e.message}"
        end

        if parts.empty?
          abort_multipart_upload(upload_id, key) if upload_id
          raise "No parts uploaded for multipart upload"
        end

        @client.complete_multipart_upload(
          bucket: @s3_config.bucket,
          key: key,
          upload_id: upload_id,
          multipart_upload: { parts: parts }
        )

        { key: key, success: true }
      rescue => e
        # Abort multipart upload on any error
        abort_multipart_upload(upload_id, key) if upload_id
        { key: key, success: false, error: e.message }
      end
    end

    def abort_multipart_upload(upload_id, key)
      return unless upload_id
      
      begin
        @client.abort_multipart_upload(
          bucket: @s3_config.bucket,
          key: key,
          upload_id: upload_id
        )
      rescue => abort_error
        # Log but don't raise - abort is best effort
        $stderr.puts "Warning: Failed to abort multipart upload #{upload_id}: #{abort_error.message}"
      end
    end
  end
end

