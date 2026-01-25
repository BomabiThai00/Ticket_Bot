require 'json'
require 'time'
require_relative 'schema'

module TicketBot
  module Prompts
    class SupportEngineer
      def initialize(subject, transcript, previous_summary = nil)
        @subject = subject
        @transcript = transcript
        @previous_summary = previous_summary
        @current_time = Time.now.strftime("%Y-%m-%d %H:%M UTC")
      end

      def build
        <<~PROMPT
          You are a Tier 3 Support Engineer.
          Your role is to analyze helpdesk logs and maintain a strict, technical state of the issue.
          You are speaking to Engineers, not Customers. Do not be polite. Be precise, factual, Technical and succinct.

          --- CURRENT CONTEXT ---
          Current Time: #{@current_time}
          Ticket Subject: #{@subject}

          --- CONSTRAINTS ---
          1. CHAIN OF THOUGHT: You MUST populate the 'analysis_scratchpad' field first. Use it to filter out "Thank you" emails, noise, and non-technical chatter.
          2. DATES: Never guess dates. Use relative times from the logs or the timestamps provided. If unknown, use "Unknown Date".
          3. EVIDENCE: Do not hallucinate root causes. If the logs are vague, categorize as "Undetermined".
          4. FORMAT: Output pure JSON only. No Markdown fencing, no preamble.

          #{construct_task_block}

          --- INPUT TRANSCRIPT ---
          #{@transcript}

          --- REQUIRED JSON SCHEMA ---
          #{JSON.pretty_generate(TicketBot::Prompts::Schema.output_structure)}
        PROMPT
      end

      private

      def construct_task_block
        if @previous_summary.nil? || @previous_summary.empty?
          <<~TASK
            --- TASK: INITIAL ANALYSIS ---
            This is a fresh analysis.
            1. Read the Transcript below.
            2. Build a complete chronological timeline of technical events.
            3. Assess the initial Root Cause based on available evidence.
          TASK
        else
          <<~TASK
            --- TASK: STATE UPDATE ---
            We have an existing state from a previous run. You must update it based on new messages.

            [PREVIOUS STATE JSON]:
            #{@previous_summary}

            INSTRUCTIONS:
            1. Parse the PREVIOUS STATE.
            2. Read the INPUT TRANSCRIPT (New messages).
            3. Append new significant events to the 'timeline_events'.
            4. Re-evaluate the 'root_cause_analysis' and 'sentiment'. Has the issue changed?
            5. Update the 'next_step' based on the latest interaction.
            6. Do not summarize broadly; be specific. Add as many points as necessary to capture the full story.
          TASK
        end
      end
    end
  end
end