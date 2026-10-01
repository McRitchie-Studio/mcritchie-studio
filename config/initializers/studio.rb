Studio.configure do |config|
  # ---- Site identity + link preview (studio-engine docs/LINK_PREVIEW.md) ----
  # The DRAFTED title and description; the operator edits them at
  # /admin/link_preview, and Studio.site_identity reads the result.
  config.site_title = "McRitchie Studio"
  config.site_description = "Alex McRitchie's studio in Denver: acquiring and growing proven businesses, and building the software and agents that run them."

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
  # Solana/web3 logic, so this app has no on-chain surface left to except. The
  # users.solana_address COLUMN followed it on the same day
  # (/tasks/drop-hub-wallet-column), which is why there is no
  # `config.wallet_address_method` below: `Studio.user_wallet_address` walks
  # [wallet_address_method, :wallet_address, :solana_address] behind a
  # `respond_to?` guard (studio-engine 0.69.3 lib/studio.rb:719), so with the
  # column gone every candidate is skipped and it returns nil on its own.
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
  config.theme_logos = [
    { file: "favicon.png",      title: "Favicon" },
    { file: "logo-icon.svg",    title: "Navbar Logo" },
    { file: "studio-logo.svg",  title: "SSO Logo" },
  ]
  # ---- Site footer and booking (studio-engine docs/SITE_FOOTER.md) ----
  # The engine renders the footer, the map, the booking frame and the booking
  # popup, and serves Leaflet. This block is only the facts.
  #
  # `name`, `wordmark`, `logo` and the directions URL are written out rather
  # than left to their defaults: the default name is the site identity's title,
  # which the operator can edit at /admin/link_preview, and the footer's
  # wordmark and © line must not move with it.
  config.site_footer = ->(view) {
    {
      name: "McRitchie Studio",
      wordmark: %w[McRitchie Studio],
      logo: "logo-icon.svg",
      logo_invert: true,
      home_path: view.root_path,
      tagline: "Software & Marketing Solutions",
      address: {
        street: "3000 Lawrence St", city_line: "Denver, CO 80205",
        lat: 39.7614786, lng: -104.978957,
        directions_url: "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205"
      },
      # [ label, icon, url ].
      social: [
        [ "LinkedIn", :linkedin, "https://www.linkedin.com/in/amcritchie/" ],
        [ "Instagram", :instagram, "https://www.instagram.com/alexmcritchie/" ],
        [ "X", :x, "https://x.com/mcritchiealex" ]
      ],
      columns: [
        # No phone number, on purpose: the operator removed it.
        # `booking: true` makes the link open the booking popup; /schedule is
        # this app's own page (ScheduleController), so the engine cannot tell
        # from the path alone. Contact is the SMS opt-in form: its helper is
        # `contact_form_path`; `contact_path` belongs to /contacts/:id.
        [ "Contact",   [ [ "team@mcritchie.studio", "mailto:team@mcritchie.studio" ],
                         [ "Schedule a call", view.schedule_index_path, { booking: true } ],
                         [ "Contact", view.contact_form_path ] ] ],
        [ "Solutions", [ [ "Packages", view.packages_path ], [ "Build an app", view.build_path ] ] ],
        # Career has no page yet: a nil path renders the label disabled.
        [ "Company",   [ [ "Home", view.root_path ], [ "About", view.about_path ], [ "Career", nil ] ] ],
        [ "Legal",     [ [ "Privacy Policy", view.privacy_path ], [ "Terms of Service", view.terms_path ] ] ]
      ],
      legal: [ [ "Privacy Policy", view.privacy_path ], [ "Terms of Service", view.terms_path ] ],
      booking: { label: "Schedule a call", title: "Book a call with Alex McRitchie" }
    }
  }

  # A visitor gets the footer on every page. A signed-in viewer gets it only on
  # these controllers, the public site; every other signed-in page is a working
  # surface (boards, queues, editors) and stays full height.
  config.site_footer_controllers = %w[landing packages build contact_submissions schedule]

  # The studio's Google Calendar appointment schedule. It checks every one of
  # the operator's calendars for conflicts, which is why bookings go through it.
  # Read it back as Studio.booking_url.
  #
  # draw_booking_routes stays off: /schedule is ScheduleController's, which
  # keeps this app's page title and its line about Alex's calendar. The engine's
  # page would replace both.
  config.booking_url = "https://calendar.google.com/calendar/appointments/schedules/" \
                       "AcZssZ3_1hQYaxXWJCG8T-AAuv6YHQN9w3aRBnp-rtQc10YqH6k6Yy6FjUTtZLnwoT27Sr30YcOuZI1K"

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

  # Cloudflare R2 when STUDIO_S3_BACKEND=r2 (with R2_PUBLIC_URL), AWS S3 otherwise
  # (no settings, the engine's defaults): config/initializers/00_storage_backend.rb.
  StorageBackend.studio_s3_settings.each { |name, value| config.public_send("#{name}=", value) }
end
