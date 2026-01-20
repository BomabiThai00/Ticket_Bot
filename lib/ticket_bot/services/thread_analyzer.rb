require 'json'
require_relative '../core/logger'
require_relative 'pii_sanitizer'

module TicketBot
  class ThreadAnalyzer
    HISTORY_LIMIT = 100 

    # Define standard Root Cause categories
    RCA_CATEGORIES = [
      "Software Bug", 
      "User Error / Education", 
      "Feature Request", 
      "Configuration Issue", 
      "Network / Infrastructure", 
      "Billing / Account",
      "Third-Party Integration",
      "Undetermined"
    ]

    def initialize(llm_client, api_client)
      @llm = llm_client
      @api = api_client
    end

    def analyze(ticket, messages)
      # 1. FIND CONTEXT
      previous_summary = find_last_ai_note(messages)
      
      # 2. SANITIZE
      safe_subject = PiiSanitizer.scrub(ticket.subject || "No Subject")
      raw_log = build_conversation_log(messages)
      sanitized_log = PiiSanitizer.scrub(raw_log)

      # 3. CALL AZURE
      Log.instance.info "   🤖 Analyzing Ticket #{ticket.number} (Timeline & RCA Mode)..."
      analysis_hash = generate_incremental_summary(safe_subject, sanitized_log, previous_summary)

      # 4. FORMAT AS HTML
      format_summary_note(analysis_hash)
    end

    private

    def find_last_ai_note(messages)
      ai_msg = messages.reverse.find do |m| 
        m.content && m.content.include?("<b>Context Summary</b>")
      end
      ai_msg ? strip_html(ai_msg.content) : nil
    end

    def build_conversation_log(messages)
      sorted = messages.sort_by { |m| m.created_at }
      logs = sorted.last(HISTORY_LIMIT).map do |m|
        next if m.content && m.content.include?("Context Summary")
        sender = m.direction == 'in' ? "CUSTOMER" : "AGENT"
        time = m.created_at.strftime('%Y-%m-%d %H:%M')
        clean_body = strip_html(m.content).gsub(/\s+/, ' ').strip[0..500]
        "[#{time}] #{sender}: #{clean_body}"
      end
      logs.compact.empty? ? "[No readable text]" : logs.compact.join("\n")
    end

    def generate_incremental_summary(subject, log, old_summary)
      context_block = old_summary ? 
        "--- PREVIOUS TIMELINE ---\n#{old_summary}\nINSTRUCTION: Append new events to this history." : 
        "INSTRUCTION: Create a fresh timeline from scratch."

      prompt = <<~PROMPT
        You are a Senior QA Lead.
        #{context_block}
        
        --- HISTORY ---
        Subject: #{subject}
        #{log}
        
        INSTRUCTIONS:
        1. Analyze the technical root cause.
        2. Categorize into EXACTLY ONE of: #{RCA_CATEGORIES.join(', ')}.
        3. Generate 3-5 distinct tags (e.g., error codes, feature names).
        4. Identify the immediate next step.
        5. **Crucial:** In 'timeline_events', list EVERY significant event, status change, or key fact in chronological order. Do not summarize broadly; be specific. Add as many points as necessary to capture the full story.

        OUTPUT JSON:
        { 
          "timeline_events": ["YYYY-MM-DD - Who: Detail of what happened", "... (add all events found)"], 
          "root_cause_analysis": {
            "category": "One of the defined categories",
            "reasoning": "Brief explanation why",
            "suggested_tags": ["tag1", "tag2", "tag3"]
          },
          "next_step": { "owner": "Role", "action": "Action" },
          "sentiment_score": 0 
        }
      PROMPT

      response = @llm.generate_response(prompt, json_mode: true, temperature: 0.1) 
      JSON.parse(response)
    end

    def format_summary_note(data)
      score = data['sentiment_score'].to_i
      mood = score > 70 ? "🔥 HIGH URGENCY" : "✅ Normal"
      
      # FIX: Now utilizing the 'events' variable correctly
      events = Array(data['timeline_events']).map { |e| "<li>#{e}</li>" }.join
      
      rca = data['root_cause_analysis'] || {}
      category = rca['category'] || "Undetermined"
      reasoning = rca['reasoning'] || "No analysis provided."
      tags = Array(rca['suggested_tags']).map { |t| "<code>#{t}</code>" }.join(" ")

      next_owner = data.dig('next_step', 'owner') || "Unassigned"
      next_action = data.dig('next_step', 'action') || "Review ticket"

      # HTML: 'Timeline' replaces 'Executive Summary'
      <<~HTML
        <b>Context Summary</b><br>
        ---------------------------------<br>
        <b>Status:</b> #{mood}<br>
        <b>Root Cause:</b> #{category}<br><br>
        
        <b>Timeline & Key Facts:</b>
        <ul>#{events}</ul>
        
        <b>Technical Analysis:</b><br>
        <i>#{reasoning}</i><br>
        <b>Tags:</b> #{tags}<br><br>
        
        <b>Next Steps:</b><br>
        <b>Owner:</b> #{next_owner}<br>
        <b>Action:</b> #{next_action}<br>
        ---------------------------------
      HTML
    end

    def strip_html(html)
      return "" if html.nil?
      html.to_s.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
    end
  end
end