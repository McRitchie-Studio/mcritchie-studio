module BroadcastsHelper
  # Per-contact greeting name, resolved for the current render target:
  #   - app send  → the contact's first name (set on @contact by BroadcastMailer)
  #   - HubSpot   → a HubSpot merge tag (export HTML, @hubspot_export)
  #   - preview   → a neutral fallback
  def broadcast_greeting_name
    @contact&.first_name.presence ||
      (@hubspot_export ? "{{ contact.firstname|default:'there' }}".html_safe : "there")
  end
end
