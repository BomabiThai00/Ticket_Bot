module TicketBot
  module Prompts
    module Schema
      # Strict technical categories for Root Cause Analysis
      RCA_CATEGORIES = [
        "Software Bug",
        "User Error / Training",
        "Configuration / Setup",
        "Infrastructure / Network",
        "Third-Party Integration",
        "Billing / Account",
        "Feature Request",
        "Undetermined / In Progress"
      ].freeze

      # The exact JSON structure the LLM must return
      def self.output_structure
        {
          "analysis_scratchpad" => "Internal monologue. Think step-by-step here. Review the evidence, discard noise, and justify your classification before filling the final JSON fields.",
          "root_cause_analysis" => {
            "category" => "One of: #{RCA_CATEGORIES.join(', ')}",
            "confidence_score" => "Integer 0-100",
            "technical_reasoning" => "Concise technical explanation of why this category was chosen.",
            "evidence_quote" => "Direct quote from the transcript supporting this conclusion (or null if none)."
          },
          "timeline_events" => [
            "YYYY-MM-DD [Who]: Specific technical event or status change (e.g., 'Logs uploaded', 'Error 500 reported')."
          ],
          "next_step" => {
            "owner" => "Support, Engineering, Carriers, Compliance,  or Customer",
            "action" => "Specific action item (e.g., 'Check Nginx logs', 'Await customer repro').",
            "is_blocked" => "Boolean"
          },
          "sentiment" => {
            "current_score" => "Integer 0 (Furious) to 100 (Delighted)",
            "frustration_velocity" => "String: 'Stable', 'Increasing', or 'Decreasing'"
          }
        }
      end
    end
  end
end