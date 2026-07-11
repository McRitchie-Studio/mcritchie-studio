Studio.configure do |config|
  config.app_name = "McRitchie Studio"
  config.session_key = :studio_user_id
  config.welcome_message = ->(user) { "Welcome to McRitchie Studio, #{user.display_name}!" }

  # Engine-owned sticky table headers (0.12.1 carries the already-sticky th
  # guard upstreamed from this app's former local copy).
  config.sticky_table_headers = true

  # Passwordless: magic-link email + Google + Solana wallet. No :password —
  # has_secure_password stays on the model only as a dormant fallback.
  config.auth_methods = %i[magic_link google wallet]
  config.registration_params = [:name, :email]

  # The magic-link MessageVerifier purpose. MUST differ from other Studio apps:
  # they share SECRET_KEY_BASE, so an identical token_name would let a link
  # minted for one app verify on another (cross-app token confusion).
  config.magic_link_token_name = "magic_link_mcritchie_v1"

  # Use the unified Studio::Link store: short /l/<token> URLs (was the long
  # /magic_link/<MessageVerifier> blob). Requires the studio_links table.
  config.magic_link_store = :database

  # Verified sending address for the active mail transport. SES uses the
  # McRitchie domain; Resend fallback uses the shared McRitchie Studio sender so
  # future apps can send before their own SES setup is complete.
  config.mailer_from = Studio.mailer_from_for_transport(
    ses_from: "McRitchie Studio <team@mcritchie.studio>"
  )

  config.configure_sso_user = ->(user) { user.role = "viewer" }
  config.sso_logo = "/studio-logo.svg"
  config.wallet_address_method = :solana_address
  config.theme_logos = [
    { file: "favicon.png",      title: "Favicon" },
    { file: "logo-icon.svg",    title: "Navbar Logo" },
    { file: "studio-logo.svg",  title: "SSO Logo" },
  ]
  # S3 (Studio::S3 — upload/url/delete against "<prefix>-<dev|production>").
  # Engine default is nil, so set it explicitly. Region defaults to us-east-2.
  config.s3_bucket_prefix = "mcritchie-studio"
end
