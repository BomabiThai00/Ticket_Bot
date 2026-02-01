require 'faraday'
require 'json'
require 'time'
require 'loofah' 
require_relative '../core/logger'
require_relative '../core/models' 
require_relative '../core/errors'

module TicketBot
  class ZohoClient
    MAX_RETRIES = 3
    MAX_TICKETS_TO_FETCH = 200
    
    IGNORED_STATUSES = ["On Hold", "Closed", "Invalid"]
    
    def base_url
      "https://desk.zoho.com/api/v1"
    end

    def initialize(config, authenticator)
      @config = config
      @auth = authenticator
    end

    def connection
      Faraday.new(url: base_url, ssl: { verify: false }) do |f|
        f.headers['Authorization'] = "Zoho-oauthtoken #{@auth.access_token}"
        f.headers['orgId'] = @config[:org_id].to_s if @config[:org_id]
        f.headers['Content-Type'] = 'application/json'
        f.adapter Faraday.default_adapter
      end
    end

    # --- Standard Getters ---
    def get_my_info; get('/myinfo'); end
    def get_organizations; get('/organizations'); end

    # --- Fetch Logic ---

    def fetch_ticket_by_number(ticket_number)
      TicketBot::Log.instance.info "   🔍 Searching for Ticket ##{ticket_number}..."
      data = get("/tickets/search?ticketNumber=#{ticket_number}&limit=1")

      if data['data'].nil? || data['data'].empty?
        TicketBot::Log.instance.error "   ❌ Ticket ##{ticket_number} not found."
        return nil
      end

      map_ticket(data['data'].first)
    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to find ticket ##{ticket_number}: #{e.message}"
      nil
    end

    def fetch_tickets(my_agent_id)
      all_tickets = []
      from_index = 1
      limit = 200

      TicketBot::Log.instance.info "   🔄 Fetching All Open Tickets..."

      loop do
        if all_tickets.size >= MAX_TICKETS_TO_FETCH
          TicketBot::Log.instance.warn "   ⚠️ Hit safety limit of #{MAX_TICKETS_TO_FETCH} tickets. Stopping fetch."
          break
        end

        url = "/tickets?status=Open&include=contacts&limit=50&from=#{from_index}"
        data = get(url)
        
        break unless data['data'] && !data['data'].empty?

        batch = data['data'].map do |t|
          next if IGNORED_STATUSES.include?(t['status'])
          map_ticket(t) # Uses Centralized Factory under private
        end.compact

        all_tickets.concat(batch)
        break if data['data'].size < limit
        from_index += limit
      end

      TicketBot::Log.instance.info "   ✅ Fetched #{all_tickets.size} valid tickets."
      all_tickets
    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to fetch tickets: #{e.message}"
      []
    end

    # --- Check most recent activity type ---
    def fetch_latest_thread(ticket_id)
      data = get("/tickets/#{ticket_id}/latestThread")
      
      return nil unless data && data['id']

      # Uses Unified Message Factory
      build_message(
        content: data['summary'], 
        direction: data['direction'], 
        channel: data['channel'],     
        created_time: data['createdTime']
      )
    rescue StandardError => e
      # 404 means no threads exist yet
      Log.instance.error "thread maybe doesn't exist yet: #{e}"
      return nil
    end

    # --- Conversation Fetching ---
    def fetch_full_conversation(ticket_id)
      # Uses the new paginated methods
      threads = fetch_threads(ticket_id)
      comments = fetch_comments(ticket_id)
      (threads + comments).sort_by(&:created_at)
    end

    def fetch_threads(ticket_id)
      fetch_paginated("/tickets/#{ticket_id}/threads") do |m|
        # Fallback to summary if content is empty
        raw_body = m['content'].to_s.empty? ? m['summary'] : m['content']
        
        build_message(
          content: raw_body,
          direction: m['direction'],
          channel: m['channel'], 
          created_time: m['createdTime']
        )
      end
    end

    def fetch_comments(ticket_id)
      fetch_paginated("/tickets/#{ticket_id}/comments") do |c|
        type = c.dig('commenter', 'type')
        direction = (type == 'endUser') ? 'in' : 'out'
        label = c['isPublic'] ? "💬 [Public Comment]" : "🔒 [Private Note]"
        
        build_message(
          content: "#{label} #{c['content']}",
          direction: direction,
          channel: nil, # Comments imply internal/web
          created_time: c['commentedTime']
        )
      end
    end

    def post_private_comment(ticket_id, html_content)
      return if html_content.nil? || html_content.strip.empty?
      post("/tickets/#{ticket_id}/comments", { isPublic: false, content: html_content, contentType: "html" })
    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to post comment on #{ticket_id}: #{e.message}"
    end

    private

    # --- FACTORIES (DRY) ---

    def map_ticket(t)
      current_count = t['threadCount'] || 0
      # Version signature for caching
      version_signature = "threads_#{current_count}"

      TicketBot::Ticket.new(
        id: t['id'],
        number: t['ticketNumber'],
        subject: t['subject'],
        assignee_id: t['assigneeId'],
        description: t['description'],
        modified_time: version_signature 
      )
    end

    def build_message(content:, direction:, channel:, created_time:)
      TicketBot::Message.new(
        content: strip_html(content),
        direction: direction,
        channel: channel,
        created_at: Time.parse(created_time)
      )
    end

    # --- HELPERS ---

    def fetch_paginated(endpoint)
      results = []
      from_index = 1
      limit = 50

      loop do
        # Handle existing query params if necessary
        separator = endpoint.include?('?') ? '&' : '?'
        url = "#{endpoint}#{separator}limit=#{limit}&from=#{from_index}"
        
        data = get(url)
        
        # 1. Guard: Stop if no data
        break if data['data'].nil? || data['data'].empty?

        # 2. Map: Apply the block (parsing logic) to each item
        batch = data['data'].map { |item| yield(item) }
        results.concat(batch)

        # 3. Stop if end of list
        break if data['data'].size < limit
        from_index += limit
      end

      results
    rescue TicketBot::Error => e
      raise e
    rescue StandardError => e
      raise TicketBot::ZohoError, "Pagination logic failed: #{e.message}"
    end

    def get(path)
      with_retries { handle_response(connection.get(base_url + path)) }
    end

    def post(path, body)
      with_retries do
        resp = connection.post(base_url + path) { |req| req.body = body.to_json }
        handle_response(resp)
      end
    end

    def handle_response(response)
      # 1. Handle Empty/Success
      return {} if response.body.nil? || response.body.strip.empty?
      
      # 2. Handle HTTP Errors
      unless response.success?
        error_msg = "Zoho #{response.status}: #{response.body}"
        
        case response.status
        when 401
          # If we are here, internal refresh logic already failed
          @auth.send(:refresh_access_token!)
          raise TicketBot::ZohoAuthError, "Forcing refresh... 401 Authentication Failed: #{error_msg}"
        when 429, 500..599
          raise TicketBot::ZohoTransientError, error_msg
        when 400..499
          raise TicketBot::ZohoError, error_msg 
        else
          raise TicketBot::ZohoError, error_msg
        end
      end

      # 3. Parse JSON
      begin
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise TicketBot::ZohoError, "Invalid JSON response: #{e.message}"
      end
    end

    def with_retries
      attempts = 0
      begin
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError => e
        attempts += 1
        if attempts <= MAX_RETRIES
          sleep(attempts * 1)
          TicketBot::Log.instance.warn "   ⚠️ Zoho API Retry (#{attempts}/#{MAX_RETRIES})..."
          retry
        else
          raise e
        end
      rescue StandardError => e
        raise e
      end
    end

    def strip_html(html)
      return "" if html.nil?
      Loofah.fragment(html).text(encode_special_chars: false).gsub(/\s+/, " ").strip
    end
  end
end