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

  # One personal value for the reader (task staged-email-queue), from the merge
  # fields BroadcastMailer#campaign resolved (Broadcasts::MergeFields). With no
  # reader (the editor's preview, the HubSpot export) it shows the field's
  # name in braces, so a preview makes plain what varies per reader. Staging
  # skips a reader missing a required field, so a send never shows the braces.
  def merge_field(key, fallback: nil)
    value = @merge_fields&.dig(key.to_s)
    return value.to_s if value.present? || value == 0

    fallback || "{#{key}}"
  end

  # A count from the merge fields with its noun, pluralized: "1 game",
  # "7 games" (Broadcasts::MergeFields.counted). With no value it shows the
  # field's name in braces, as merge_field does: "{games} games".
  def merge_count(key, noun)
    value = @merge_fields&.dig(key.to_s)
    return Broadcasts::MergeFields.counted(value, noun) if value.present? || value == 0

    "{#{key}} #{noun.pluralize}"
  end
end
