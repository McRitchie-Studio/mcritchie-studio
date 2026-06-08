module BroadcastsHelper
  # Per-contact greeting name, resolved for the current render target:
  #   - app send  → the contact's first name (set on @contact by BroadcastMailer)
  #   - HubSpot   → a HubSpot merge tag (export HTML, @hubspot_export)
  #   - preview   → a neutral fallback
  def broadcast_greeting_name
    @contact&.first_name.presence ||
      (@hubspot_export ? "{{ contact.firstname|default:'there' }}".html_safe : "there")
  end

  # A CTA/hero link: the click-tracking URL when sending (mailer sets
  # @tracked_urls), otherwise the raw destination (preview/export).
  def broadcast_link(key, raw_url)
    (@tracked_urls && @tracked_urls[key]) || raw_url
  end
end
