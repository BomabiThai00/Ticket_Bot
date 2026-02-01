require 'faraday'
require 'json'
require 'time'
require_relative '../core/logger'
require_relative '../core/errors'

module TicketBot
  class LlmClient
    # Configuration for Azure OAuth
    AZURE_TOKEN_URL = "https://login.microsoftonline.com/%s/oauth2/v2.0/token"
    AZURE_SCOPE = "https://cognitiveservices.azure.com/.default" 

    DEPLOYMENT_NAME = ENV['AZURE_DEPLOYMENT_NAME'] || "gpt-5.1-chat"
    ENDPOINT_BASE   = ENV['AZURE_ENDPOINT_URL'] || "https://ticketbot-gpt.cognitiveservices.azure.com"

    PROVIDERS = {
      azure: {
        url: "#{ENDPOINT_BASE.chomp('/')}/openai/deployments/#{DEPLOYMENT_NAME}/chat/completions?api-version=2025-01-01-preview",
        adapter: :azure_adapter
      }
    }

    def initialize
      @tenant_id = ENV['AZURE_TENANT_ID']
      @client_id = ENV['AZURE_CLIENT_ID']
      @client_secret = ENV['AZURE_CLIENT_SECRET']
      
      if [@tenant_id, @client_id, @client_secret].any? { |v| v.nil? || v.empty? }
        raise TicketBot::LlmError, "Missing Azure OAuth Credentials in .env" 
      end

      @access_token = nil
      @token_expires_at = Time.now
    end

    def generate_response(prompt_text, json_mode: false, temperature: 1)
      call_provider(:azure, prompt_text, json_mode, temperature)
    end

    private

    def call_provider(provider_name, prompt, json_mode, temperature)
      config = PROVIDERS[provider_name]
      token = fetch_oauth_token

      conn = Faraday.new(ssl: { verify: false }, request: { timeout: 120, open_timeout: 120 })
      body = send(config[:adapter], prompt, json_mode, temperature, config)
      
      response = conn.post(config[:url]) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Authorization'] = "Bearer #{token}"
        req.body = body.to_json
        
      end

      handle_provider_response(provider_name, response)
    rescue Faraday::TimeoutError
      raise TicketBot::LlmTransientError, "Azure Connection Timed Out"
    rescue Faraday::ConnectionFailed => e
      raise TicketBot::LlmTransientError, "Azure Connection Failed: #{e.message}"
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
        raise TicketBot::LlmError, "OAuth Token Failed (Status #{resp.status}): #{resp.body}"
      end
    end

    def azure_adapter(prompt, json_mode, temp, _config)
      system_content = "You are an Expert Technical Support Engineer at Maqsam."
      system_content += " Please output valid JSON." if json_mode

      body = {
        messages: [
          { role: "system", content: system_content },
          { role: "user", content: prompt }
        ],
        temperature: temp,
        max_completion_tokens: 8000
      }
      body[:response_format] = { type: "json_object" } if json_mode
      body
    end

    def handle_provider_response(provider, response)
      # Success Case
      if response.success?
        begin
          data = JSON.parse(response.body)
          content = data.dig('choices', 0, 'message', 'content')
          
          if content.nil? || content.empty?
            raise TicketBot::LlmError, "Azure returned 200 OK but content was empty."
          end
          
          return content
        rescue JSON::ParserError
          raise TicketBot::LlmError, "Failed to parse valid JSON from Azure response."
        end
      end

      # Error Cases (Unified Handling)
      error_msg = "#{provider} API #{response.status}: #{response.body}"

      case response.status
      when 408, 429, 500..599
        # Retryable errors (Server errors, Rate limits, Timeouts)
        raise TicketBot::LlmTransientError, error_msg
      when 401, 403
        # Auth errors (Token rejected) - Critical
        raise TicketBot::LlmError, "Authorization Failed: #{error_msg}"
      when 400..499
        # Client errors (Bad Request, Deployment Not Found)
        raise TicketBot::LlmError, error_msg
      else
        raise TicketBot::LlmError, "Unknown Status: #{error_msg}"
      end
    end
  end
end