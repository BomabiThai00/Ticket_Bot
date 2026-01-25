require 'json'
require 'loofah' # High-performance HTML stripping
require_relative '../core/logger'
require_relative 'pii_sanitizer'
require_relative '../prompts/support_engineer'

module TicketBot
  class ThreadAnalyzer
    HISTORY_CHAR_LIMIT = 15_000 
    BOT_SIGNATURE = "Context Summary"

    def initialize(llm_client, api_client)
      @llm = llm_client
      @api = api_client
    end

    def analyze(ticket, messages)
      # 1. Sort once.
      # We receive a mix of threads and comments. We ensure they are perfectly linear.
      sorted_msgs = messages.sort_by(&:created_at)

      # 2. EXTRACT STATE
      # efficiently scan backwards for the last JSON payload
      previous_json_state = extract_state_from_history(sorted_msgs)

      # 3. PREPARE DATA
      safe_subject = PiiSanitizer.scrub(ticket.subject || "No Subject")
      transcript = build_clean_transcript(sorted_msgs)

      # 4. BUILD PROMPT
      prompt_builder = TicketBot::Prompts::SupportEngineer.new(
        safe_subject, 
        transcript, 
        previous_json_state
      )
      
      Log.instance.info "   🤖 Analyzing Ticket #{ticket.number} (Mode: #{previous_json_state ? 'Update' : 'Fresh'})..."

      # 5. EXECUTE LLM
      raw_response = @llm.generate_response(prompt_builder.build, json_mode: true, temperature: 0.1)
      return if raw_response.nil?

      begin
        analysis_data = JSON.parse(raw_response)
        
        # 6. GENERATE HTML NOTE
        format_summary_note(analysis_data)
      rescue JSON::ParserError => e
        Log.instance.error "   ❌ Failed to parse LLM JSON: #{e.message}"
        nil
      end
    end

    private

    def extract_state_from_history(sorted_messages)
      # Reverse iterator avoids duplicating the array
      sorted_messages.reverse_each do |m|
        # We only care about notes posted by THIS bot
        next unless m.content && m.content.include?("<b>#{BOT_SIGNATURE}</b>")
        
        # Extract the hidden JSON block
        match = m.content.match(//m)
        return match[1].strip if match
      end
      nil
    end

    def build_clean_transcript(sorted_messages)
      buffer = []
      
      sorted_messages.each do |m|
        # Skip our own summaries to prevent recursive context loops
        next if m.content && m.content.include?(BOT_SIGNATURE)

        sender = m.direction == 'in' ? "CUSTOMER" : "AGENT"
        
        # Add a visual indicator if this is a Private Note
        if m.channel != 'EMAIL'
           sender += " (INTERNAL NOTE)" 
        end

        time = m.created_at.strftime('%Y-%m-%d %H:%M')
        
        # OPTIMIZATION: Loofah is C-based and much safer/faster than Regex
        raw_text = Loofah.fragment(m.content.to_s).text(encode_special_chars: false)
        
        # Scrub PII
        clean_body = PiiSanitizer.scrub(raw_text).strip.gsub(/\s+/, ' ')

        buffer << "[#{time}] #{sender}: #{clean_body}"
      end

      # Truncate if we exceed the context window
      full_text = buffer.join("\n")
      if full_text.length > HISTORY_CHAR_LIMIT
        "...(older logs truncated)...\n" + full_text[(-HISTORY_CHAR_LIMIT)..-1]
      else
        full_text
      end
    end

    def format_summary_note(data)
      rca = data['root_cause_analysis'] || {}
      next_step = data['next_step'] || {}
      sentiment = data['sentiment'] || {}
      timeline = data['timeline_events'] || []

      status_icon = (sentiment['current_score'].to_i < 40) ? "🔴 CRITICAL" : "🟢 STABLE"
      timeline_html = timeline.map { |e| "<li>#{e}</li>" }.join
      
      # We embed the JSON state secretly at the bottom for the next run
      json_payload = ""

      <<~HTML
        <b>#{BOT_SIGNATURE}</b> | #{status_icon}<br>
        --------------------------------------------------<br>
        
        <b>🔍 Root Cause Analysis</b><br>
        <b>Category:</b> #{rca['category']} (#{rca['confidence_score']}%)<br>
        <b>Reasoning:</b> <i>#{rca['technical_reasoning']}</i><br>
        #{rca['evidence_quote'] ? "<b>Evidence:</b> \"#{rca['evidence_quote']}\"<br>" : ''}
        <br>

        <b>⏭️ Next Steps</b><br>
        <b>Owner:</b> #{next_step['owner']}<br>
        <b>Action:</b> #{next_step['action']} #{next_step['is_blocked'] ? '(⛔ BLOCKED)' : ''}<br>
        <br>

        <b>📅 Technical Timeline</b>
        <ul>#{timeline_html}</ul>

        <div style="font-size: 10px; color: #888;">
          Frustration Velocity: #{sentiment['frustration_velocity']}
        </div>
        #{json_payload}
      HTML
    end
  end
end