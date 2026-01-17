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
      # fetch_tickets returns [TicketBot::Ticket] or []
      tickets = @client.fetch_tickets(@config[:view_id]) || []
      
      tickets.each do |ticket|
        # OPTIONAL: Uncomment to process only your own tickets
        next if ticket.assignee_id != @config[:my_agent_id]

        # Dispatch to worker pool
        # We do NOT check tracker here because we need to fetch threads first
        # to know the count. That network call should happen asynchronously.
        @pool.post { process_ticket_async(ticket) }
      end
    rescue StandardError => e
      Log.instance.error "Main Loop Error: #{e.message}"
      Log.instance.error e.backtrace.join("\n")
    end

    def process_ticket_async(ticket)
      # 1. Fetch current context (Network Call)
      messages = @client.fetch_threads(ticket.id)
      current_count = messages.size

      # 2. Tracker Logic: Should we skip?
      #    Now passes 'current_count' to check the Delta < 5 rule
      if @tracker.should_skip?(ticket.id, current_count)
        # Log.instance.debug "   zzz Skipping #{ticket.number} (Insufficient new data)"
        return
      end

      Log.instance.info "🔥 Processing #{ticket.number} (Count: #{current_count})..."

      # 3. Analyze (AI / Computation)
      analysis = @analyzer.analyze(ticket, messages)
      
      # 4. Post Result (Network Call)
      @client.post_private_comment(ticket.id, analysis)
      
      # 5. Commit state to DB
      #    Only update if analysis and posting succeeded
      @tracker.update_tracking(ticket.id, current_count)
      
      Log.instance.info "   ✅ Updated #{ticket.number}"
    rescue StandardError => e
      Log.instance.error "   💥 Error on #{ticket.number}: #{e.message}"
    end
  end
end