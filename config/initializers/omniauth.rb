# frozen_string_literal: true

# config/initializers/canonical_host.rb requires this too; `require` is idempotent,
# and naming it here keeps this file readable on its own.
require Rails.root.join("lib/middleware/canonical_host")

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV["GOOGLE_CLIENT_ID"],
    ENV["GOOGLE_CLIENT_SECRET"],
    scope: "email,profile",
    prompt: "select_account"
end

OmniAuth.config.allowed_request_methods = [:post]

# Pin the callback to the canonical host.
#
# Unset, omniauth builds `redirect_uri` from the host the request arrived on. This app
# answers on several allowlisted names (APP_HOST_ALIASES), so beginning a sign-in on
# `www.` or the legacy `app.` subdomain handed Google a callback URL that its OAuth
# client had never been shown — `Error 400: redirect_uri_mismatch`, reported as an
# account problem because it tracked whichever browser profile held the alias
# bookmark. Pinned, every front door produces the single registered callback.
#
# CanonicalHost 301s browsers onto the canonical host already, but deliberately leaves
# anything other than GET and HEAD alone — and the omniauth request phase is a POST
# (allowed_request_methods above). This is what covers it, and taking both answers
# from CanonicalHost is what stops the front door and the callback drifting apart.
#
# nil off a deployed app (no APP_HOST), which leaves omniauth's per-request behaviour
# untouched for localhost and worktree desks on their own ports.
CanonicalHost.pin_omniauth!(OmniAuth.config)
