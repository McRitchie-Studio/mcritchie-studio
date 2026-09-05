Studio.configure do |config|
  config.app_name = "McRitchie Studio"
  config.session_key = :studio_user_id
  config.welcome_message = ->(user) { "Welcome to McRitchie Studio, #{user.display_name}!" }

  # Engine-owned sticky table headers (0.12.1 carries the already-sticky th
  # guard upstreamed from this app's former local copy).
  config.sticky_table_headers = true

  # Engine-owned smooth-load convention (0.24): layouts/studio/_smooth_load
  # renders the view-transition + no-preview metas, engine.css ships the
  # transition styling and the vt-pinned-header @utility. This replaced the
  # app-local partial/CSS copy. Under no-preview the old page holds until the
  # fresh response, so drop the nav spinner floor from the engine's 2500ms
  # default to a fast-load 300ms.
  config.smooth_load = true
  # Out-of-the-box navigation (engine 0.30): the sidebar data stays in the
  # hub's LinkTreeHelper; the engine renders it. The lambda hands the view
  # context over so the helper keeps its route helpers and admin? wall.
  config.sidebar_sections = ->(view) { view.sidebar_link_sections }
  config.nav_spinner_min_ms = 300

  # Passwordless: magic-link email + Google. No :password — has_secure_password
  # stays on the model only as a dormant fallback.
  #
  # No :wallet, deliberately. The hub carries no on-chain PRODUCT surface —
  # wallet identity belongs to turf-monster — and studio-engine draws
  # /auth/solana/nonce, /auth/solana/verify and /auth/phantom/callback behind
  # `Studio.auth_method?(:wallet)`, so dropping it REMOVES those routes rather
  # than merely hiding a button. The admin signing console used to be the one
  # exception worth naming here — `require_admin` only, driving Phantom in the
  # signer's own browser, so it never read a wallet SESSION. It was DELETED on
  # 2026-09-04 (/tasks/retire-signing-console): Turf Monster is the hub for all
  # Solana/web3 logic, so this app has no on-chain surface left to except.
  #
  # EDIT this line, never delete it: studio-engine's own default is still
  # %i[magic_link google wallet] (0.65.2, lib/studio.rb), so an absent line
  # would silently re-enable wallet auth. Every consumer pins its methods.
  config.auth_methods = %i[magic_link google]
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
  # Draw the engine's standard email page at /admin/emails (Studio::EmailsController
  # over Studio::EmailCatalog). Opt-in because turf-monster's own routes.rb already
  # claims that path and the admin_emails_path helper; this app claims neither, so
  # it takes the shared page instead of keeping a fork. Retires /admin/email_images.
  config.draw_admin_emails_routes = true

  # Draw the engine's first-name onboarding endpoints (Studio::OnboardingController
  # at /onboarding/first_name + /onboarding/skip_first_name). Opt-in for the same
  # reason as the page above: turf-monster owns those two helper names in its own
  # routes.rb until its adoption lands. This app claims neither.
  #
  # No onboarding_steps_resolver is set, so the engine's default applies: nothing
  # further after the name. That is correct here — the name is the only thing this
  # app asks a new account, unlike turf's welcome → name → age → wallet chain.
  config.draw_onboarding_routes = true

  # S3 (Studio::S3 — upload/url/delete against "<prefix>-<dev|production>").
  # Engine default is nil, so set it explicitly. Region defaults to us-east-2.
  config.s3_bucket_prefix = "mcritchie-studio"
end
