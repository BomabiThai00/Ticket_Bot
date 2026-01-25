require 'faraday'
require 'json'
require 'time'
require_relative '../core/logger'
require_relative '../core/models' 

module TicketBot
  class ZohoClient
    # BASE_URL = 'https://desk.zoho.com/api/v1'
    MAX_RETRIES = 3
    MAX_TICKETS_TO_FETCH = 100
    
    IGNORED_STATUSES = ["On Hold", "Closed"]
    
    def base_url
      tld = ENV['ZOHO_TOP_LEVEL_DOMAIN'] || 'com'
      "https://desk.zoho.#{tld}/api/v1"
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
    def get_views; get('/views?module=tickets'); end

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
      limit = 50

      TicketBot::Log.instance.info "   🔄 Fetching tickets for Agent ID #{my_agent_id}..."

      loop do
        if all_tickets.size >= MAX_TICKETS_TO_FETCH
          TicketBot::Log.instance.warn "   ⚠️ Hit safety limit of #{MAX_TICKETS_TO_FETCH} tickets. Stopping fetch."
          break
        end
        url = "/tickets?assignee=#{my_agent_id}&status=Open&include=contacts&limit=50"
        # url = "/tickets?viewId=#{agent_id}&include=contacts&limit=#{limit}&from=#{from_index}"
        data = get(url)
        
        break unless data['data'] && !data['data'].empty?

        batch = data['data'].map do |t|
          next if IGNORED_STATUSES.include?(t['status'])
          map_ticket(t)
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

    def map_ticket(t)
      TicketBot::Ticket.new(
        id: t['id'],
        number: t['ticketNumber'],
        subject: t['subject'],
        assignee_id: t['assigneeId'],
        description: t['description'],
        modified_time: t['modifiedTime'] #Capture the timestamp
      )
    end

    # ---Check most recent activity type ---
    def fetch_latest_thread(ticket_id)
      data = get("/tickets/#{ticket_id}/latestThread")
      
      return nil unless data && data['id']

      TicketBot::Message.new(
        content: strip_html(data['summary']),
        direction: data['direction'], 
        channel: data['channel'],     
        created_at: Time.parse(data['createdTime'])
      )
    rescue StandardError => e
      # 404 means no threads exist yet
      Log.instance.error "thread maybe doesn't exist yet: #{e}"
      return nil
    end

    # --- Conversation Fetching ---
    def fetch_full_conversation(ticket_id)
      threads = fetch_threads(ticket_id)
      comments = fetch_comments(ticket_id)
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
            channel: m['channel'], 
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
          type = c.dig('commenter', 'type')
          direction = (type == 'endUser') ? 'in' : 'out'
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

    def post_private_comment(ticket_id, html_content)
      return if html_content.nil? || html_content.strip.empty?
      post("/tickets/#{ticket_id}/comments", { isPublic: false, content: html_content, contentType: "html" })
    rescue StandardError => e
      TicketBot::Log.instance.error "   ❌ Failed to post comment on #{ticket_id}: #{e.message}"
    end

    private

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
      if response.status == 401
        TicketBot::Log.instance.warn "⚠️  401 Unauthorized. Token expired/revoked. Forcing refresh..."
        
        # 1. Force the authenticator to refresh (We need to bypass the expiry check)
        # Note: You may need to expose a public 'refresh!' method in Authenticator.rb
        @auth.send(:refresh_access_token!) 
        
        # 2. Raise a specific retryable error that 'with_retries' can catch
        raise Faraday::ServerError.new("Token Refreshed - Retrying") 
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