# Hardened now that the hub carries sensitive auth (magic-link + Solana wallet),
# not just email/password. httponly keeps the session cookie out of JS (XSS
# can't lift it); secure pins it to HTTPS in prod; same_site :lax blocks
# cross-site POST CSRF while still allowing the top-level OAuth callback
# navigation. (Adding these flags is also the prerequisite turf-monster's
# docs/AUTH.md named for safely restoring cross-app SSO later.)
session_key = Rails.env.production? ? "_studio_session" : ENV.fetch("MCRITCHIE_SESSION_KEY", "_studio_session")

Rails.application.config.session_store :cookie_store,
  key: session_key,
  domain: (Rails.env.production? ? ".mcritchie.studio" : :all),
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
