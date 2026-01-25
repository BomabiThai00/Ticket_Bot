require 'faraday'
require 'json'
require 'thread'
require_relative 'core/logger'

module TicketBot
  class Authenticator
    # TOKEN_URL = 'https://accounts.zoho.com/oauth/v2/token'
    ENV_FILE_PATH = './.env'

    def self.token_url
      tld = ENV['ZOHO_TOP_LEVEL_DOMAIN'] || 'com'
      "https://accounts.zoho.#{tld}/oauth/v2/token"
    end

    def initialize
      @client_id = ENV['ZOHO_CLIENT_ID']
      @client_secret = ENV['ZOHO_CLIENT_SECRET']
      @refresh_token = ENV['ZOHO_REFRESH_TOKEN']
      
      # 1. Access ZOHO_ACCESS_TOKEN from ENV
      @access_token = ENV['ZOHO_ACCESS_TOKEN']
      
      # We also need to load the expiry time to know if the ENV token is valid
      # If no expiry is found in ENV, default to a time in the past (force refresh)
      @expires_at = ENV['ZOHO_TOKEN_EXPIRY'] ? Time.parse(ENV['ZOHO_TOKEN_EXPIRY']) : Time.now - 10

      @lock = Mutex.new
      validate_env!
    end

    def access_token
      @lock.synchronize do
        # 2. Run token_expired?
        if token_expired?
          # 3. True => Run refresh_access_token!
          refresh_access_token!
        end
        
        # 4. False (or after refresh) => Return token
        return @access_token
      end
    end

    private

    def validate_env!
      if [@client_id, @client_secret, @refresh_token].any? { |v| v.nil? || v.empty? }
        Log.instance.error "❌ Missing OAuth Credentials. Check your .env file."
        raise "Missing Zoho OAuth Credentials"
      end
    end

    def token_expired?
      # Buffer time (e.g. 60s) ensures we refresh slightly before actual expiry
      is_expired = Time.now >= (@expires_at - 60)
      
      if is_expired
        Log.instance.error "❌ Token is expired (or missing). Triggering refresh."
      end
      
      is_expired
    end

    def refresh_access_token!
      Log.instance.info "🔄 Refreshing Zoho Access Token..."

      conn = Faraday.new(url: self.class.token_url, ssl: { verify: false })
      
      response = conn.post do |req|
        req.body = {
          refresh_token: @refresh_token,
          client_id:     @client_id,
          client_secret: @client_secret,
          grant_type:    'refresh_token'
        }
      end

      data = JSON.parse(response.body)

      if data['error']
        Log.instance.error "❌ OAuth Error: #{data['error']}"
        raise "Zoho OAuth Failed: #{data['error']}"
      end

      # Update instance variables
      @access_token = data['access_token']
      expires_in_seconds = data['expires_in'].to_i
      @expires_at = Time.now + expires_in_seconds

      Log.instance.info "✅ Token Refreshed. Expires in #{expires_in_seconds}s."

      # Update .env file with BOTH token and new expiry time
      update_env_file("ZOHO_ACCESS_TOKEN", @access_token)
      update_env_file("ZOHO_TOKEN_EXPIRY", @expires_at.to_s)
    
    rescue StandardError => e
      Log.instance.error "⚠️ Error during Auth process: #{e.message}"
      raise e
    end

    def update_env_file(key, value)
      content = File.exist?(ENV_FILE_PATH) ? File.read(ENV_FILE_PATH) : ""
      
      if content.match?(/^#{key}=/)
        # Update existing key
        content = content.gsub(/^#{key}=.*/, "#{key}=#{value}")
      else
        # Append new key
        prefix = content.empty? || content.end_with?("\n") ? "" : "\n"
        content += "#{prefix}#{key}=#{value}\n"
      end
      
      File.write(ENV_FILE_PATH, content)
    rescue StandardError => e
      Log.instance.error "⚠️ Error updating .env file: #{e.message}"
      raise e
    end
  end
end