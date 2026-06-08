class BroadcastMailer < ApplicationMailer
  helper :broadcasts # BroadcastsHelper#broadcast_greeting_name (mailers don't auto-include app helpers)

  # Renders a broadcast for ONE contact: personalized greeting, public S3 images,
  # and a working per-contact unsubscribe link. Delivered via Resend.
  def campaign(broadcast, contact)
    @broadcast        = broadcast
    @contact          = contact
    @email_asset_host = Broadcasts::Assets.base_url
    @unsubscribe_url  = unsubscribe_url(token: contact.unsubscribe_token, **url_host_options)

    mail(to: contact.email, subject: @broadcast.subject.presence || "(no subject)") do |format|
      format.html { render template: "broadcasts/#{@broadcast.template_key}", layout: "broadcast_email" }
    end
  end

  private

  # Unsubscribe links must be absolute. The dev default_url_options pins port
  # 3000 (the main app), but this broadcasts worktree serves on :3030 — so pass
  # host + port explicitly. Set BROADCAST_HOST in prod (e.g. app.mcritchie.studio).
  def url_host_options
    if (host = ENV["BROADCAST_HOST"]).present?
      { host: host }
    elsif Rails.env.production?
      { host: "app.mcritchie.studio" }
    else
      { host: "127.0.0.1", port: 3030 }
    end
  end
end
