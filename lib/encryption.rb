# frozen_string_literal: true

require 'gpgme'
require 'openssl'
require 'digest'
require 'tempfile'

module DokSnap
  class Encryption
    attr_reader :method
    
    def initialize(method:, public_key: nil, password: nil, key_id: nil)
      @method = method
      @public_key = public_key
      @password = password
      @key_id = key_id  # Optional explicit key ID/fingerprint
    end

    def encrypt(input_path, output_path)
      case @method
      when 'gpg'
        encrypt_gpg(input_path, output_path)
      when 'aes256'
        encrypt_aes256(input_path, output_path)
      else
        raise "Unsupported encryption method: #{@method}"
      end
    end

    private

    def encrypt_gpg(input_path, output_path)
      crypto = GPGME::Crypto.new
      
      # Import public key if needed (using GPGME API)
      keys = GPGME::Key.find(:public, nil)
      
      if keys.empty?
        import_public_key
        keys = GPGME::Key.find(:public, nil)
      end

      if keys.empty?
        raise 'No GPG public keys found. Please import a public key.'
      end

      # Use explicit key ID if provided, otherwise use first key
      if @key_id
        # Validate that the specified key exists
        matching_key = keys.find { |k| k.fingerprint == @key_id || k.keyid == @key_id }
        unless matching_key
          raise "Specified GPG key ID not found: #{@key_id}. Available keys: #{keys.map(&:fingerprint).join(', ')}"
        end
        key_id = matching_key.fingerprint
      else
        # Use first key but validate it's valid
        key_id = keys.first.fingerprint
        if keys.length > 1
          $stderr.puts "Warning: Multiple GPG keys found. Using #{key_id}. Specify key_id in config to use a specific key."
        end
      end

      File.open(input_path, 'rb') do |input|
        File.open(output_path, 'wb') do |output|
          # Remove always_trust - validate keys properly
          crypto.encrypt(input, output: output, recipients: key_id)
        end
      end
    rescue GPGME::Error => e
      raise "GPG encryption failed: #{e.message}"
    end

    def import_public_key
      return unless @public_key

      begin
        ctx = GPGME::Ctx.new
        result = ctx.import_keys(@public_key)
        
        if result.imported == 0 && result.unchanged == 0
          raise 'Failed to import GPG public key. Invalid key format.'
        end
      rescue GPGME::Error => e
        raise "GPG key import failed: #{e.message}"
      end
    end

    def encrypt_aes256(input_path, output_path)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.encrypt
      
      # Derive key from password using PBKDF2 with SHA256 (not SHA1)
      salt = OpenSSL::Random.random_bytes(16)
      # Use SHA256 instead of SHA1, with 100,000 iterations
      key = OpenSSL::PKCS5.pbkdf2_hmac_sha256(@password, salt, 100_000, cipher.key_len)
      iv = cipher.random_iv
      
      cipher.key = key
      cipher.iv = iv

      File.open(output_path, 'wb') do |output|
        # Write salt and IV first
        output.write([salt.length].pack('N'))
        output.write(salt)
        output.write([iv.length].pack('N'))
        output.write(iv)
        
        # Write encrypted data
        File.open(input_path, 'rb') do |input|
          while chunk = input.read(4096)
            output.write(cipher.update(chunk))
          end
          output.write(cipher.final)
        end
      end
    end
  end
end
