require 'faraday'
require 'json'
require 'time'
require_relative '../core/logger'
require_relative '../core/models' 

module TicketBot
  class ZohoClient
    BASE_URL = 'https://desk.zoho.com/api/v1'
    MAX_RETRIES = 3
    
    MAX_TICKETS_TO_FETCH = 100
    
    # Statuses we do not want to process
    IGNORED_STATUSES = [
      "On Hold", 
      "Closed"
    ]

    def initialize(config, authenticator)
      @config = config
      @auth = authenticator
    end

    def connection
      Faraday.new(url: BASE_URL, ssl: { verify: false }) do |f|
        f.headers['Authorization'] = "Zoho-oauthtoken #{@auth.access_token}"
        f.headers['orgId'] = @config[:org_id].to_s if @config[:org_id]
        f.headers['Content-Type'] = 'application/json'
        f.adapter Faraday.default_adapter
      end
    end

    # --- Standard Getters ---
    def get_my_info; get('/myinfo'); end
    def get_organizations; get('/organizations'); end
    def get_views; get('/views?module=tickets'); end

    # --- Core Fetch Logic (Refactored) ---
    def fetch_tickets(view_id)
      all_tickets = []
      from_index = 1
      limit = 50

      TicketBot::Log.instance.info "   🔄 Fetching tickets from View #{view_id}..."

      loop do
        # Safety Break
        if all_tickets.size >= MAX_TICKETS_TO_FETCH
          TicketBot::Log.instance.warn "   ⚠️ Hit safety limit of #{MAX_TICKETS_TO_FETCH} tickets. Stopping fetch."
          break
        end

        # Pagination Request
        url = "/tickets?viewId=#{view_id}&include=contacts&limit=#{limit}&from=#{from_index}"
        data = get(url)
        
        # Stop if API returns nothing useful
        break unless data['data'] && !data['data'].empty?

        # Process Batch
        batch = data['data'].map do |t|
          # Filter: Status check
          next if IGNORED_STATUSES.include?(t['status'])

          TicketBot::Ticket.new(
            id: t['id'],
            number: t['ticketNumber'],
            subject: t['subject'],
            assignee_id: t['assigneeId'],
            description: t['description']
          )
        end.compact

        all_tickets.concat(batch)

        # Pagination Logic: If we got fewer results than limit, we are done.
        break if data['data'].size < limit
        from_index += limit
      end

      TicketBot::Log.instance.info "   ✅ Fetched #{all_tickets.size} valid tickets."
      all_tickets

    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to fetch tickets: #{e.message}"
      # Always return an empty array on error, never nil
      []
    end

    # --- Conversation Fetching (Threads + Comments) ---
    def fetch_full_conversation(ticket_id)
      threads = fetch_threads(ticket_id)
      comments = fetch_comments(ticket_id)
      
      # Merge and Sort Chronologically
      (threads + comments).sort_by(&:created_at)
    end

    def fetch_threads(ticket_id)
      begin
        data = get("/tickets/#{ticket_id}/threads?limit=50")
        return [] unless data['data']

        data['data'].map do |m|
          raw_body = m['content'].nil? || m['content'].empty? ? m['summary'] : m['content']
          
          TicketBot::Message.new(
            content: strip_html(raw_body),
            direction: m['direction'], 
            created_at: Time.parse(m['createdTime'])
          )
        end
      rescue StandardError => e
        TicketBot::Log.instance.error "   ❌ Failed threads for #{ticket_id}: #{e.message}"
        []
      end
    end

    def fetch_comments(ticket_id)
      begin
        data = get("/tickets/#{ticket_id}/comments?limit=50")
        return [] unless data['data']

        data['data'].map do |c|
          # Determine Sender: 'endUser' = Customer (in), 'agentUser' = Agent (out)
          type = c.dig('commenter', 'type')
          direction = (type == 'endUser') ? 'in' : 'out'
          
          # Add label so AI knows this is a comment/note
          label = c['isPublic'] ? "💬 [Public Comment]" : "🔒 [Private Note]"
          raw_body = c['content']
          
          TicketBot::Message.new(
            content: "#{label} #{strip_html(raw_body)}",
            direction: direction,
            created_at: Time.parse(c['createdTime'])
          )
        end
      rescue StandardError => e
        TicketBot::Log.instance.error "   ❌ Failed comments for #{ticket_id}: #{e.message}"
        []
      end
    end

    # --- Posting Logic ---
    def post_private_comment(ticket_id, html_content)
      return if html_content.nil? || html_content.strip.empty?
      
      # Send as 'html' so Zoho renders tags like <b> and <ul>
      post("/tickets/#{ticket_id}/comments", { 
        isPublic: false, 
        content: html_content,
        contentType: "html" 
      })
    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to post comment on #{ticket_id}: #{e.message}"
    end

    private

    def get(path)
      with_retries { handle_response(connection.get(BASE_URL + path)) }
    end

    def post(path, body)
      with_retries do
        resp = connection.post(BASE_URL + path) { |req| req.body = body.to_json }
        handle_response(resp)
      end
    end

    def handle_response(response)
      if response.status == 401
        TicketBot::Log.instance.error "⚠️  401 Unauthorized. Token expired."
        raise "Zoho Auth Error: 401"
      elsif !response.success?
        raise "Zoho API Error: #{response.status} - #{response.body}"
      end
      JSON.parse(response.body)
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
      html.to_s.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
    end
  end
end