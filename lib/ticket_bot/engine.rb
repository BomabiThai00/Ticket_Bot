$stdout.sync = true
$stderr.sync = true

require 'concurrent'
require_relative 'core/logger'
require_relative 'core/configuration'
require_relative 'core/tracker'
require_relative 'core/errors' 
require_relative 'clients/llm_client'
require_relative 'services/thread_analyzer'

module TicketBot
  class Engine
    CONCURRENCY_LIMIT = 1
    CACHE_LIMIT = 1000

    def initialize(config, client)
      @config = config
      @client = client
      @llm = LlmClient.new
      @tracker = Tracker.new
      @analyzer = ThreadAnalyzer.new(@llm, @client)
      @pool = Concurrent::FixedThreadPool.new(CONCURRENCY_LIMIT)
      
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
      Log.instance.info "   - Tracker: Email-Only Volume Strategy"
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
      tickets = @client.fetch_tickets(@config[:my_agent_id]) || []
      
      tickets.each do |ticket|
        next if ticket.assignee_id != @config[:my_agent_id]
        @pool.post { process_ticket_async(ticket) }
      end
    rescue StandardError => e
      Log.instance.error "Main Loop Error: #{e.message}"
      Log.instance.error e.backtrace.join("\n")
    end

    def process_ticket_async(ticket, force_update: false)
      # 1. L1 Cache: Check & Refresh LRU position (Safe to do outside error block)
      if !force_update && check_and_refresh_cache(ticket.id, ticket.modified_time)
        Log.instance.info "   ⏭️  Skipping #{ticket.number}: In-Memory Cache Hit (No changes detected)."
        return 
      end

      #  START UNIFIED ERROR HANDLING BLOCK
      begin
        # 2. Robust Check: Last Email must be from Customer
        unless force_update
          latest = @client.fetch_latest_thread(ticket.id)
          
          # Guard 1: No messages at all
          if latest.nil?
            Log.instance.info "   ⏭️  Skipping #{ticket.number}: No thread/messages found (Empty Ticket)."
            update_cache(ticket.id, ticket.modified_time)
            return
          end

          # Guard 2: Last message was outgoing (Agent replied already)
          if latest.direction != 'in'
            Log.instance.info "   ⏭️  Skipping #{ticket.number}: Last message was from AGENT (Waiting for customer reply)."
            update_cache(ticket.id, ticket.modified_time)
            return
          end

          # Guard 3: Last message wasn't an email
          if latest.channel != 'EMAIL'
            Log.instance.info "   ⏭️  Skipping #{ticket.number}: Last message channel was '#{latest.channel}' (Only processing EMAIL)."
            update_cache(ticket.id, ticket.modified_time)
            return
          end
        end

        # 3. Fetch Full Context
        # (This may now raise TicketBot::ZohoError or TicketBot::TransientError)
        messages = @client.fetch_full_conversation(ticket.id)
        
        # Filter to count ONLY Emails
        email_count = messages.count { |m| m.channel == 'EMAIL' }

        # 4. Tracker Logic (L2 DB Check)
        unless force_update
          if @tracker.should_skip?(ticket.id, email_count)
            Log.instance.info "   ⏭️  Skipping #{ticket.number}: Volume Threshold not met (Emails: #{email_count})."
            update_cache(ticket.id, ticket.modified_time)
            return
          end
        end

        # Extract count from metadata signature "threads_123"
        raw_count_sig = ticket.modified_time || "threads_0"
        current_thread_count = raw_count_sig.split('_').last.to_i
        
        # Secondary Tracker Check
        unless force_update
          if @tracker.should_skip?(ticket.id, current_thread_count)
            Log.instance.info "   ⏭️  Skipping #{ticket.number}: Volume Threshold not met (Total: #{current_thread_count})."
            update_cache(ticket.id, ticket.modified_time)
            return
          end
        end

        Log.instance.info "🔥 Processing #{ticket.number} (Emails: #{email_count} | Total Context: #{messages.size})..."

        # 5. Analyze
        # (This may now raise TicketBot::LlmError or TicketBot::LlmTransientError)
        analysis = @analyzer.analyze(ticket, messages)

        # Guard: Ensure analysis isn't empty/nil before proceeding
        if analysis.nil? || analysis.to_s.strip.empty?
          raise TicketBot::LlmError, "Analysis returned empty result."
        end

        # 6. Post Result
        @client.post_private_comment(ticket.id, analysis)
        
        # 7. Commit state (CRITICAL: Only reached if everything above succeeded)
        @tracker.update_tracking(ticket.id, email_count)
        update_cache(ticket.id, ticket.modified_time)
        
        Log.instance.info "   ✅ Updated #{ticket.number}"

      # --- ERROR HANDLERS ---

      rescue TicketBot::TransientError => e
        # Retryable errors (500s, Timeouts, Rate Limits)
        Log.instance.warn "   ⏳ Transient Error for #{ticket.number}: #{e.message}. Retrying next cycle."
        # We implicitly return, so @tracker.update_tracking is NEVER called.

      rescue TicketBot::PermanentError => e
        # Fatal errors (400 Bad Request, Auth Failed, Parsing Logic)
        Log.instance.error "   ❌ Permanent Error for #{ticket.number}: #{e.message}. Skipping."
        
      rescue StandardError => e
        # Catch-all for unexpected code crashes (NilPointer, Syntax)
        Log.instance.error "   💀 Unexpected Crash on #{ticket.number}: #{e.message}"
        Log.instance.debug e.backtrace.join("\n")
      end
    end

    # --- Thread-Safe LRU Cache Helpers ---

    def check_and_refresh_cache(id, remote_time)
      @cache_lock.synchronize do
        cached_time = @processed_cache[id]
        
        if cached_time == remote_time
          Log.instance.info "🕵️ CACHE VERIFY: Ticket #{id} - Verdict: MATCH"
          @processed_cache.delete(id)
          @processed_cache[id] = remote_time
          return true
        end
        false
      end
    end

    def update_cache(id, remote_time)
      @cache_lock.synchronize do
        @processed_cache.delete(id)
        @processed_cache[id] = remote_time
        @processed_cache.shift if @processed_cache.size > CACHE_LIMIT
      end
    end
  end
end