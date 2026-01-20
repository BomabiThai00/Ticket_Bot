$stdout.sync = true
$stderr.sync = true

require 'concurrent'
require_relative 'core/logger'
require_relative 'core/configuration'
require_relative 'core/tracker'
require_relative 'clients/llm_client'
require_relative 'services/thread_analyzer'

module TicketBot
  class Engine
    TARGET_VIEW_NAME = "Open Cases"
    CONCURRENCY_LIMIT = 1

    def initialize(config, client)
      @config = config
      @client = client
      @llm = LlmClient.new
      @tracker = Tracker.new
      @analyzer = ThreadAnalyzer.new(@llm, @client)
      @pool = Concurrent::FixedThreadPool.new(CONCURRENCY_LIMIT)
    end

    def run
      # --- Single Ticket Mode (By Number) ---
      if ENV['SINGLE_TICKET_NUMBER']
        number = ENV['SINGLE_TICKET_NUMBER']
        Log.instance.info "🚀 Single Ticket Mode Active for Ticket Number: #{number}"
        
        should_force = ENV['FORCE_UPDATE'] == 'true'
        Log.instance.info "   ⚡ Force Update: ENABLED (Bypassing DB check)" if should_force

        # This will fetch the ticket and internally map the correct ID
        ticket = @client.fetch_ticket_by_number(number)

        if ticket
          # Process synchronously to ensure completion before exit
          process_ticket_async(ticket, force_update: should_force)
          Log.instance.info "👋 Single run complete."

        else
          Log.instance.error "❌ Could not retrieve ticket with number: #{number}"
        end

        return # Exit immediately
      end

      # --- Standard Polling Mode ---
      bootstrap_configuration unless configured?
      Log.instance.info "🤖 Bot Online. Agent ID: #{@config[:my_agent_id]}"
      Log.instance.info "   - Concurrency: #{CONCURRENCY_LIMIT} Threads"
      Log.instance.info "   - Tracker: Incremental Mode (WAL Enabled)"

      loop do
        check_cycle
        sleep(60)
      end
    rescue Interrupt
      Log.instance.info "🛑 Shutting down worker pool..."
      @pool.shutdown
      @pool.wait_for_termination
      Log.instance.info "👋 Shutdown complete."
    end

    private

    def configured?
      @config[:org_id] && @config[:view_id] && @config[:my_agent_id]
    end

    def bootstrap_configuration
      Log.instance.info "⚙️  Auto-detecting settings..."
      
      # 1. Org
      orgs = @client.get_organizations
      if orgs['data']
        @config[:org_id] = orgs['data'].first['id']
        Log.instance.info "   ✅ Org Set: #{@config[:org_id]}"
      end

      # 2. View
      views = @client.get_views
      target = views['data']&.find { |v| v['name'].downcase == TARGET_VIEW_NAME.downcase }
      
      if target
        @config[:view_id] = target['id']
        Log.instance.info "   ✅ View Set: #{target['id']}"
      else
        Log.instance.error "❌ View '#{TARGET_VIEW_NAME}' not found."
        exit(1)
      end

      # 3. Agent Identity
      my_info = @client.get_my_info
      id = my_info['id']
      name = my_info['firstName']

      if id
        @config[:my_agent_id] = id
        Log.instance.info "   ✅ Identity Verified: #{name} (ID: #{id})"
      else
        Log.instance.error "❌ Could not fetch Agent Identity."
        exit(1)
      end
    end

    def check_cycle
      tickets = @client.fetch_tickets(@config[:view_id]) || []
      
      tickets.each do |ticket|

        next if ticket.assignee_id != @config[:my_agent_id]

        @pool.post { process_ticket_async(ticket) }
      end
    rescue StandardError => e
      Log.instance.error "Main Loop Error: #{e.message}"
      Log.instance.error e.backtrace.join("\n")
    end

    def process_ticket_async(ticket, force_update: false)
      # 1. Fetch threads using the ID (which was populated by fetch_ticket_by_number)
      messages = @client.fetch_threads(ticket.id)
      current_count = messages.size

      # 2. Tracker Logic
      unless force_update
        if @tracker.should_skip?(ticket.id, current_count)
          Log.instance.info("Ticket #{ticket.number} has already been processed, bouncing back...")
          return
        end
      end

      Log.instance.info "🔥 Processing #{ticket.number} (Count: #{current_count})..."

      # 3. Analyze
      analysis = @analyzer.analyze(ticket, messages)
      
      # 4. Post Result
      @client.post_private_comment(ticket.id, analysis)
      
      # 5. Commit state
      @tracker.update_tracking(ticket.id, current_count)
      
      Log.instance.info "   ✅ Updated #{ticket.number}"
    rescue StandardError => e
      Log.instance.error "   💥 Error on #{ticket.number}: #{e.message}"
    end
  end
end