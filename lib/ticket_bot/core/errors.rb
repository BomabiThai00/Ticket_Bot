module TicketBot
  class Error < StandardError; end

  # Transient Errors (Retry later)
  # Examples: 503 Service Unavailable, 429 Rate Limit, Timeouts
  class TransientError < Error; end
  
  # Configuration/Logic Errors (Fix code/env)
  # Examples: 400 Bad Request, 404 Not Found (if critical), Invalid JSON
  class PermanentError < Error; end

  # Specific Implementations
  class ZohoError < Error; end
  class ZohoTransientError < TransientError; end
  class ZohoAuthError < PermanentError; end # 

  class LlmError < PermanentError; end
  class LlmTransientError < TransientError; end
end