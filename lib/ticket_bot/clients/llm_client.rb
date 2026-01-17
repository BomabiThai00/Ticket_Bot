require 'faraday'
require 'json'
require 'time'
require_relative '../core/logger'

module TicketBot
  class LlmClient
    # Configuration for Azure OAuth
    AZURE_TOKEN_URL = "https://login.microsoftonline.com/%s/oauth2/v2.0/token"
    AZURE_SCOPE = "https://cognitiveservices.azure.com/.default" 

    PROVIDERS = {
      azure: {
        url: "https://mbxc-mkfct6r7-swedencentral.cognitiveservices.azure.com/openai/deployments/gpt-4.1/chat/completions?api-version=2025-01-01-preview",
        adapter: :azure_adapter
      }
    }

    def initialize
      @tenant_id = ENV['AZURE_TENANT_ID']
      @client_id = ENV['AZURE_CLIENT_ID']
      @client_secret = ENV['AZURE_CLIENT_SECRET']
      
      if [@tenant_id, @client_id, @client_secret].any? { |v| v.nil? || v.empty? }
        Log.instance.error "🛑 FATAL: Missing Azure OAuth Credentials in .env."
        abort("🛑 Script aborted due to missing configuration.") 
      end

      @access_token = nil
      @token_expires_at = Time.now
    end

    def generate_response(prompt_text, json_mode: false, temperature: 0.2)
      call_provider(:azure, prompt_text, json_mode, temperature)
    end

    private

    def call_provider(provider_name, prompt, json_mode, temperature)
      config = PROVIDERS[provider_name]
      token = fetch_oauth_token

      conn = Faraday.new(ssl: { verify: false })
      body = send(config[:adapter], prompt, json_mode, temperature, config)
      
      response = conn.post(config[:url]) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Authorization'] = "Bearer #{token}"
        req.body = body.to_json
      end

      if response.status == 401 || response.status == 403
        Log.instance.error "🛑 FATAL: Azure rejected the Access Token (Status #{response.status})."
        abort("🛑 Script aborted due to AI Authorization failure.")
      end

      parse_response(provider_name, response)
    rescue StandardError => e
      Log.instance.error "💥 #{provider_name} Connection Error: #{e.message}"
      nil 
    end

    def fetch_oauth_token
      if @access_token && Time.now < (@token_expires_at - 300)
        return @access_token
      end

      Log.instance.info "🔑 Fetching new Azure Entra ID Token..."
      url = AZURE_TOKEN_URL % @tenant_id
      
      conn = Faraday.new(ssl: { verify: false })
      resp = conn.post(url) do |req|
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form({
          grant_type: 'client_credentials',
          client_id: @client_id,
          client_secret: @client_secret,
          scope: AZURE_SCOPE
        })
      end

      if resp.status == 200
        data = JSON.parse(resp.body)
        @access_token = data['access_token']
        @token_expires_at = Time.now + (data['expires_in'] || 3599).to_i
        Log.instance.info "   ✅ Token Acquired"
        return @access_token
      else
        Log.instance.error "🛑 OAuth Token Failed. Body: #{resp.body}"
        raise "OAuth Token Failed: Status #{resp.status}"
      end
    end

    def azure_adapter(prompt, json_mode, temp, _config)
      # REFACTORED: Removed Markdown instructions.
      system_content = "You are an Expert Technical Support Engineer at Maqsam."
      system_content += " Please output valid JSON." if json_mode

      body = {
        messages: [
          { role: "system", content: system_content },
          { role: "user", content: prompt }
        ],
        temperature: temp,
        max_tokens: 4000
      }
      body[:response_format] = { type: "json_object" } if json_mode
      body
    end

    def parse_response(provider, response)
      return nil if response.nil?

      begin
        data = JSON.parse(response.body)
      rescue JSON::ParserError
        Log.instance.error "❌ Response not JSON."
        return nil
      end
      
      if response.status != 200
        error_msg = data.dig('error', 'message') || "Unknown API Error"
        Log.instance.error "❌ #{provider} API Error: #{error_msg}"
        return nil
      end

      data.dig('choices', 0, 'message', 'content')
    end
  end
end