require 'thread'

module TicketBot
  class Configuration
    def initialize
      @data = {}
      @lock = Mutex.new
      load_from_env
    end

    # Thread-safe reader
    def [](key)
      @lock.synchronize { @data[key] }
    end

    # Thread-safe writer (In-Memory Only)
    def []=(key, value)
      @lock.synchronize do
        @data[key] = value
      end
    end

    private

    def load_from_env
      # Map ENV variables to internal config keys
      @data[:org_id]      = ENV['ZOHO_ORG_ID']
      @data[:my_agent_id] = ENV['ZOHO_AGENT_ID']
    
    end
  end
end