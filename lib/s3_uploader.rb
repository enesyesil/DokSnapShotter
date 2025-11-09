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
      Aws::S3::Client.new(
        access_key_id: @s3_config.access_key_id,
        secret_access_key: @s3_config.secret_access_key,
        region: @s3_config.region,
        endpoint: @s3_config.endpoint == 's3.amazonaws.com' ? nil : "https://#{@s3_config.endpoint}",
        force_path_style: @s3_config.endpoint != 's3.amazonaws.com' # Path-style for custom endpoints
      )
    end

    def generate_s3_key(metadata)
      app_name = metadata[:app_name]
      timestamp = metadata[:timestamp].gsub(/[:\-]/, '').gsub(/T/, '_').split('.').first
      filename = metadata[:filename]
      "backups/#{app_name}/#{timestamp}_#{filename}"
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

      File.open(file_path, 'rb') do |file|
        while chunk = file.read(chunk_size)
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

      @client.complete_multipart_upload(
        bucket: @s3_config.bucket,
        key: key,
        upload_id: upload_id,
        multipart_upload: { parts: parts }
      )

      { key: key, success: true }
    rescue => e
      # Abort multipart upload on error
      begin
        @client.abort_multipart_upload(
          bucket: @s3_config.bucket,
          key: key,
          upload_id: upload_id
        )
      rescue
        # Ignore abort errors
      end
      
      { key: key, success: false, error: e.message }
    end
  end
end

