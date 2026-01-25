require 'sqlite3'
require 'thread'
require_relative 'logger'

module TicketBot
  class Tracker
    DB_FILE =  DB_FILE = ENV['DB_PATH'] || File.expand_path('../../../processed_tickets.db', __dir__)
    
    # Retry settings for when database is locked 
    MAX_RETRIES = 5
    BASE_SLEEP_SECONDS = 0.1

    def initialize
      @lock = Mutex.new
      connect_and_configure_db
    end

    def needs_processing?(ticket_id, remote_modified_at)
      begin
        row = execute_with_retry do
          @db.get_first_row("SELECT processed_at FROM processed_history WHERE ticket_id = ?", ticket_id.to_s)
        end

        # If no record exists, we definitely need to process it
        return true if row.nil?

        # Parse DB time
        last_processed = Time.parse(row['processed_at'] + " UTC")
        
        # Buffer: Add 1 second to DB time to avoid precision issues
        # If Remote Time is newer than DB Time, we process.
        Time.parse(remote_modified_at) > (last_processed + 1)
      rescue StandardError => e
        Log.instance.warn "⚠️ DB Check failed: #{e.message}. Defaulting to PROCESS."
        true # Default to process on error
      end
    end

    def should_skip?(ticket_id, current_thread_count)
      begin
        row = execute_with_retry do
          @db.get_first_row(
            "SELECT last_thread_count FROM processed_history WHERE ticket_id = ?", 
            ticket_id.to_s
          )
        end

        if row.nil?
           Log.instance.info "      [Tracker] New Ticket (Not in DB). Processing."
           return false
        end

        last_count = row['last_thread_count'].to_i
        diff = current_thread_count - last_count
        
        Log.instance.info "      [Tracker] Email Delta: #{diff} (New: #{current_thread_count}, Old: #{last_count}). Need 5."

        diff < 5
      rescue StandardError => e
        Log.instance.error "⚠️ Tracker Read Failed: #{e.message}"
        false
      end
    end

    def update_tracking(ticket_id, current_thread_count)
      begin
        execute_with_retry do
          # Use IMMEDIATE transaction to prevent deadlocks during concurrent writes
          @db.transaction(:immediate) do
            @db.execute(
              "INSERT INTO processed_history (ticket_id, last_thread_count, processed_at) 
               VALUES (?, ?, CURRENT_TIMESTAMP)
               ON CONFLICT(ticket_id) DO UPDATE SET 
                 last_thread_count = excluded.last_thread_count,
                 processed_at = CURRENT_TIMESTAMP",
              [ticket_id.to_s, current_thread_count]
            )
          end
        end
      rescue StandardError => e
        # If we exhausted retries, we MUST log this as a critical failure.
        Log.instance.error "💥 Tracker Write Failed (Ticket #{ticket_id}): #{e.message}"
        # We re-raise so the Engine knows this ticket wasn't saved.
        raise e
      end
    end

    private

    def execute_with_retry
      retries = 0
      begin
        yield
      rescue SQLite3::BusyException, SQLite3::LockedException => e
        if retries < MAX_RETRIES
          retries += 1
          # Exponential backoff with jitter to prevent thundering herd
          sleep_time = (BASE_SLEEP_SECONDS * (2 ** retries)) + rand(0.05)
          Log.instance.warn "   ⚠️ DB Locked. Retrying (#{retries}/#{MAX_RETRIES}) in #{sleep_time.round(2)}s..."
          sleep(sleep_time)
          retry
        else
          raise e
        end
      end
    end

    def connect_and_configure_db
      begin
        @db = SQLite3::Database.new(DB_FILE)
        @db.results_as_hash = true

        # WAL Mode allows Readers and Writers to work simultaneously
        @db.execute("PRAGMA journal_mode = WAL;") 
        @db.execute("PRAGMA synchronous = NORMAL;") 
        
        @db.busy_timeout = 10000 
        
        ensure_schema_exists

      rescue StandardError => e
        Log.instance.error "💥 FATAL: Database Connection Failed: #{e.message}"
        raise e
      end
    end

    def ensure_schema_exists
      execute_with_retry do
        @db.execute <<-SQL
          CREATE TABLE IF NOT EXISTS processed_history (
            ticket_id TEXT PRIMARY KEY,
            last_thread_count INTEGER DEFAULT 0,
            processed_at DATETIME DEFAULT CURRENT_TIMESTAMP
          );
        SQL
        @db.execute <<-SQL
          CREATE INDEX IF NOT EXISTS idx_processed_at ON processed_history(processed_at);
        SQL
      end
    end
  end
end