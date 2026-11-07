# Hardened now that the hub carries sensitive auth (magic-link + Solana wallet),
# not just email/password. httponly keeps the session cookie out of JS (XSS
# can't lift it); secure pins it to HTTPS in prod; same_site :lax blocks
# cross-site POST CSRF while still allowing the top-level OAuth callback
# navigation. (Adding these flags is also the prerequisite turf-monster's
# docs/AUTH.md named for safely restoring cross-app SSO later.)
#
# The name and domain per environment, and why QA keeps its own cookie, are in
# lib/session_cookie.rb (task qa-own-session-cookie).
require Rails.root.join("lib/session_cookie").to_s

options = SessionCookie.options(production: Rails.env.production?, qa: Studio::EnvironmentBanner.qa_environment?)
Rails.application.config.session_store :cookie_store, **options
