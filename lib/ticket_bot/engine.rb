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
    
    # Bounded Cache
    CACHE_LIMIT = 1000

    def initialize(config, client)
      @config = config
      @client = client
      @llm = LlmClient.new
      @tracker = Tracker.new
      @analyzer = ThreadAnalyzer.new(@llm, @client)
      @pool = Concurrent::FixedThreadPool.new(CONCURRENCY_LIMIT)
      
      # Thread-safe Cache State
      @processed_cache = {}
      @cache_lock = Mutex.new
    end

    def run
      if ENV['SINGLE_TICKET_NUMBER']
        number = ENV['SINGLE_TICKET_NUMBER']
        should_force = ENV['FORCE_UPDATE'] == 'true'

        Log.instance.info "🚀 Single Ticket Mode Active for Ticket Number: #{number}"
        Log.instance.info "   ⚡ Force Update: ENABLED" if should_force
        
        ticket = @client.fetch_ticket_by_number(number)

        if ticket
          process_ticket_async(ticket, force_update: should_force)
        else
          Log.instance.error "❌ Could not retrieve ticket with number: #{number}"
        end

        Log.instance.info "👋 Single run complete."
        return
      end

      bootstrap_configuration unless configured?
      Log.instance.info "🤖 Bot Online. Agent ID: #{@config[:my_agent_id]}"
      Log.instance.info "   - Concurrency: #{CONCURRENCY_LIMIT} Threads"
      Log.instance.info "   - Tracker: Incremental Mode (WAL Enabled)"
      Log.instance.info "   - Cache: LRU Strategy (Limit: #{CACHE_LIMIT})"

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
      
      orgs = @client.get_organizations
      if orgs['data']
        @config[:org_id] = orgs['data'].first['id']
        Log.instance.info "   ✅ Org Set: #{@config[:org_id]}"
      end

      views = @client.get_views
      target = views['data']&.find { |v| v['name'].downcase == TARGET_VIEW_NAME.downcase }
      
      if target
        @config[:view_id] = target['id']
        Log.instance.info "   ✅ View Set: #{target['id']}"
      else
        Log.instance.error "❌ View '#{TARGET_VIEW_NAME}' not found."
        exit(1)
      end

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
      # 1. L1 Cache: Check & Refresh LRU position
      #    If the timestamp matches what we have in memory, we skip INSTANTLY.
      if !force_update && check_and_refresh_cache(ticket.id, ticket.modified_time)
        return 
      end

      # 2. Robust Check: Latest Thread Analysis
      #    Before fetching all threads, check if the latest update was a Customer Email.
      unless force_update
        latest = @client.fetch_latest_thread(ticket.id)
        
        # If no threads, or the update was an Agent Reply or System Note...
        if latest.nil? || latest.direction != 'in' || latest.channel != 'EMAIL'
          # We update the cache so we don't check this ticket again until it changes
          update_cache(ticket.id, ticket.modified_time)
          return
        end
      end

      # 3. Fetch Full Threads
      messages = @client.fetch_threads(ticket.id)
      current_count = messages.size

      # 4. Tracker Logic (L2 DB Check)
      #    Final safeguard: do we have enough *new* messages?
      unless force_update
        if @tracker.should_skip?(ticket.id, current_count)
          update_cache(ticket.id, ticket.modified_time)
          return
        end
      end

      Log.instance.info "🔥 Processing #{ticket.number} (Count: #{current_count})..."

      # 5. Analyze
      analysis = @analyzer.analyze(ticket, messages)
      
      # 6. Post Result
      @client.post_private_comment(ticket.id, analysis)
      
      # 7. Commit state & Update Cache
      @tracker.update_tracking(ticket.id, current_count)
      update_cache(ticket.id, ticket.modified_time)
      
      Log.instance.info "   ✅ Updated #{ticket.number}"
    rescue StandardError => e
      Log.instance.error "   💥 Error on #{ticket.number}: #{e.message}"
    end

    # --- Thread-Safe LRU Cache Helpers ---

    def check_and_refresh_cache(id, time)
      @cache_lock.synchronize do
        if @processed_cache[id] == time
          # LRU Logic: "Use" the item by moving it to the end (Delete & Re-insert)
          @processed_cache.delete(id)
          @processed_cache[id] = time
          return true
        end
        false
      end
    end

    def update_cache(id, time)
      @cache_lock.synchronize do
        @processed_cache.delete(id)
        @processed_cache[id] = time
        @processed_cache.shift if @processed_cache.size > CACHE_LIMIT
      end
    end
  end
end