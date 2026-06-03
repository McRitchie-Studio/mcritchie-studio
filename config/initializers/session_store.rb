# Hardened now that the hub carries sensitive auth (magic-link + Solana wallet),
# not just email/password. httponly keeps the session cookie out of JS (XSS
# can't lift it); secure pins it to HTTPS in prod; same_site :lax blocks
# cross-site POST CSRF while still allowing the top-level OAuth callback
# navigation. (Adding these flags is also the prerequisite turf-monster's
# docs/AUTH.md named for safely restoring cross-app SSO later.)
Rails.application.config.session_store :cookie_store,
  key: "_studio_session",
  domain: (Rails.env.production? ? ".mcritchie.studio" : :all),
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
