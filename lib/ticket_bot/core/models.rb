module TicketBot
  # A standard Ticket object that looks the same for Zoho, HubSpot, or Zendesk
  Ticket = Struct.new(
    :id,            # The platform's unique ID
    :number,        # Human-readable ticket number
    :subject,       # The issue title
    :assignee_id,   # Who owns it
    :description,   # Initial content
    keyword_init: true
  )

  # A standard Message object
  Message = Struct.new(
    :content,       # The text body
    :direction,     # 'in' (customer) or 'out' (agent)
    :created_at,    
    keyword_init: true
  )
end