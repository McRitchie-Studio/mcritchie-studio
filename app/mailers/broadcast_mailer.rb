class BroadcastMailer < ApplicationMailer
  helper :broadcasts # BroadcastsHelper#broadcast_greeting_name (mailers don't auto-include app helpers)
  default from: -> { Studio.marketing_from_for_transport(ses_from: "Alex McRitchie <alex@mcritchie.studio>") }

  # Renders a broadcast for ONE contact: personalized greeting, public S3 images,
  # a per-contact unsubscribe link, and (when a delivery is given) the open pixel
  # + click-tracking links. Delivery uses the shared Studio mail transport.
  def campaign(broadcast, contact, delivery = nil)
    @broadcast        = broadcast
    @contact          = contact
    @email_asset_host = Broadcasts::Assets.base_url
    @unsubscribe_url  = unsubscribe_url(token: contact.unsubscribe_token, **url_host_options)

    if delivery
      @open_pixel_url = email_open_url(token: delivery.token, **url_host_options)
      @tracked_urls = Broadcast::TRACKED_LINKS.keys.index_with do |key|
        email_click_url(token: delivery.token, l: key, **url_host_options)
      end.symbolize_keys
    end

    mail(to: contact.email, subject: @broadcast.subject.presence || "(no subject)") do |format|
      format.html { render template: "broadcasts/#{@broadcast.template_key}", layout: "broadcast_email" }
    end
  end

  private

  # Unsubscribe links must be absolute. The dev default_url_options pins port
  # 3000 (the main app), but worktrees serve on allocated ports — so pass host +
  # port explicitly. Set BROADCAST_HOST in prod (e.g. mcritchie.studio).
  def url_host_options
    if (host = ENV["BROADCAST_HOST"]).present?
      { host: host }
    elsif Rails.env.production?
      { host: "mcritchie.studio" }
    else
      { host: "127.0.0.1", port: 3030 }
    end
  end
end
