module TicketBot
  class PiiSanitizer
    PATTERNS = {
      email:        /\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b/,
      phone:        /\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4,9}\b/,
      ip_v4:        /\b(?:\d{1,3}\.){3}\d{1,3}\b/,
      sip_uri:      /sip:(?:[^@]+)@(?:[^:;>]+)/,
      jwt_token:    /Bearer\s+[a-zA-Z0-9\-_]+\.[a-zA-Z0-9\-_]+\.[a-zA-Z0-9\-_]+/,
      url_params:   /(\?|&)([^=\s]+)=([^&\s]+)/
    }

    def self.scrub(text)
      return "" if text.nil?
      safe_text = text.dup

      # Scrub Secrets first
      safe_text.gsub!(PATTERNS[:jwt_token], '[AUTH_TOKEN_REDACTED]')
      safe_text.gsub!(PATTERNS[:sip_uri], '[SIP_URI]')
      safe_text.gsub!(/https?:\/\/[^\s]+/) { |url| url.gsub(/\?.*$/, '[URL_PARAMS_REMOVED]') }

      # Scrub PII
      safe_text.gsub!(PATTERNS[:email], '[EMAIL]')
      safe_text.gsub!(PATTERNS[:ip_v4], '[IP_ADDR]')
      safe_text.gsub!(PATTERNS[:phone]) do |match|
        match.gsub(/[^0-9]/, '').length > 7 ? '[PHONE]' : match
      end

      safe_text
    end
  end
end