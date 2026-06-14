Studio.configure do |config|
  config.app_name = "McRitchie Studio"
  config.session_key = :studio_user_id
  config.welcome_message = ->(user) { "Welcome to McRitchie Studio, #{user.display_name}!" }

  # Passwordless: magic-link email + Google + Solana wallet. No :password —
  # has_secure_password stays on the model only as a dormant fallback.
  config.auth_methods = %i[magic_link google wallet]
  config.registration_params = [:name, :email]

  # The magic-link MessageVerifier purpose. MUST differ from other Studio apps:
  # they share SECRET_KEY_BASE, so an identical token_name would let a link
  # minted for one app verify on another (cross-app token confusion).
  config.magic_link_token_name = "magic_link_mcritchie_v1"

  # Verified sending address for the active mail transport. SES is the target;
  # Resend remains a rollback path. Use mcritchie.studio only after DNS/DKIM is
  # verified for the selected provider.
  config.mailer_from = ENV.fetch("MAILER_FROM", "noreply@turfmonster.media")

  config.configure_sso_user = ->(user) { user.role = "viewer" }
  config.sso_logo = "/studio-logo.svg"
  config.theme_logos = [
    { file: "favicon.png",      title: "Favicon" },
    { file: "logo-icon.svg",    title: "Navbar Logo" },
    { file: "studio-logo.svg",  title: "SSO Logo" },
  ]
  # S3 bucket prefix uses engine default ("mcritchie-studio") — no override needed.
end
