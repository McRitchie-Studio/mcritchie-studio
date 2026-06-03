# Resend transactional email wiring (magic-link sign-in).
#
# Becomes the ActionMailer delivery method when RESEND_API_KEY is set (prod, and
# any dev shell that has the key in .env). Without it, delivery falls back to the
# Rails default — locally that's a no-op to local SMTP, so magic-link emails
# won't actually arrive (use a minted link instead).
#
# NOTE: we set ActionMailer::Base.delivery_method DIRECTLY, not
# `config.action_mailer.delivery_method`. config/initializers run AFTER the
# action_mailer.set_configs framework initializer has already applied the
# configured delivery method, so a config assignment here is silently ignored
# (it would stay :smtp). The direct assignment takes effect immediately.
#
# Sending domain: MAILER_FROM must be a Resend-verified domain or Resend 422s.
# (Verify in Resend → Settings → Domains; turf uses turfmonster.media.)
if ENV["RESEND_API_KEY"].present? && !Rails.env.test?
  require "resend"

  Resend.api_key = ENV["RESEND_API_KEY"]
  ActionMailer::Base.delivery_method = :resend
end
