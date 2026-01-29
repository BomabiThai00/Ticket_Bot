# lib/ticket_bot/core/errors.rb
module TicketBot
  class Error < StandardError; end

  # 1. Transient Errors (Retry later)
  # Examples: 503 Service Unavailable, 429 Rate Limit, Timeouts
  class TransientError < Error; end
  
  # 2. Configuration/Logic Errors (Fix code/env)
  # Examples: 400 Bad Request, 404 Not Found (if critical), Invalid JSON
  class PermanentError < Error; end

  # 3. Specific Implementations
  class ZohoError < Error; end
  class ZohoTransientError < TransientError; end
  class ZohoAuthError < PermanentError; end # Or Transient if you have auto-refresh

  class LlmError < PermanentError; end
  class LlmTransientError < TransientError; end
end