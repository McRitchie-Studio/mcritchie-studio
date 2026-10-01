class BroadcastMailer < ApplicationMailer
  helper :broadcasts # BroadcastsHelper#broadcast_greeting_name (mailers don't auto-include app helpers)
  default from: -> { Studio.marketing_from_for_transport(ses_from: "Alex McRitchie <alex@mcritchie.studio>") }

  # Renders a broadcast for ONE contact: personalized greeting, public S3 images,
  # a per-contact unsubscribe link, and (when a delivery is given) the open pixel
  # + click-tracking links. Delivery uses the shared Studio mail transport.
  # `merge_fields` are the reader's personal values (Broadcasts::MergeFields):
  # the subject's %{field}s and the body's merge_field helper read them. A
  # staged send renders through here once, at staging, and stores the result.
  def campaign(broadcast, contact, delivery = nil, merge_fields: nil)
    @broadcast        = broadcast
    @contact          = contact
    @merge_fields     = merge_fields || Broadcasts::MergeFields.for(contact)
    @email_asset_host = Broadcasts::Assets.base_url
    # `d` names the email the reader unsubscribed from, for the analytics.
    @unsubscribe_url  = unsubscribe_url(token: contact.unsubscribe_token, d: delivery&.token, **url_host_options)

    if delivery
      @open_pixel_url = email_open_url(token: delivery.token, **url_host_options)
      @tracked_urls = @broadcast.link_keys.index_with do |key|
        email_click_url(token: delivery.token, l: key, **url_host_options)
      end.symbolize_keys
    end

    list_unsubscribe_headers(@unsubscribe_url)

    mail(to: contact.email, subject: @broadcast.subject_for(@merge_fields)) do |format|
      format.html { render template: "broadcasts/#{@broadcast.template_key}", layout: "broadcast_email" }
    end
  end

  # Sends a staged email's stored snapshot exactly as it was approved: its
  # recipient, subject and body, nothing re-rendered (task staged-email-queue).
  # Only the headers are rebuilt, from the same token the body's links carry.
  def staged(staged_email)
    raise ArgumentError, "staged email #{staged_email.id} has no rendered body" if staged_email.rendered_html.blank?

    unsubscribe = unsubscribe_url(token: staged_email.contact.unsubscribe_token, d: staged_email.delivery_token, **url_host_options)
    list_unsubscribe_headers(unsubscribe)

    mail(to: staged_email.email, subject: staged_email.rendered_subject) do |format|
      format.text { render plain: staged_email.rendered_text } if staged_email.rendered_text.present?
      format.html { render html: staged_email.rendered_html.html_safe, layout: false } # rubocop:disable Rails/OutputSafety -- our own render, stored at staging
    end
  end

  private

  # One-click unsubscribe (RFC 8058), which Gmail and Yahoo require of bulk
  # senders: the mail client POSTs "List-Unsubscribe=One-Click" to this URL,
  # which UnsubscribesController#create accepts without a form token.
  def list_unsubscribe_headers(url)
    headers["List-Unsubscribe"] = "<#{url}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
  end

  # Unsubscribe/tracking links must be absolute and point at the environment
  # that sent the email. BROADCAST_HOST is an optional campaign-specific
  # override; otherwise use the app's mailer defaults so QA/worktree links follow
  # MAILER_HOST/APP_PORT instead of silently pointing at another host.
  def url_host_options
    options = Rails.application.config.action_mailer.default_url_options.to_h.symbolize_keys
    options[:host] = ENV["BROADCAST_HOST"] if ENV["BROADCAST_HOST"].present?
    options[:host] ||= "localhost"
    options[:port] ||= ENV["APP_PORT"].to_i if !Rails.env.production? && ENV["APP_PORT"].present?
    options
  end
end
