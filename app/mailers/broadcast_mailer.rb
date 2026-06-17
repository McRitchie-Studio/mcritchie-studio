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
