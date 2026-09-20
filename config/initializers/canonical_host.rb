# frozen_string_literal: true

# Mount the canonical-host redirect (see lib/middleware/canonical_host.rb for the
# redirect_uri_mismatch it exists to prevent).
#
# It belongs near the front: alias traffic should be turned around before sessions,
# routing, and the throttles spend anything on it. It stays behind EdgeGuard, which
# takes position 0 in its own initializer — a direct-to-origin request should be
# refused as a bypass, not handed a redirect that teaches it the canonical name.
#
# Anchored on Rack::Sendfile rather than on ActionDispatch::HostAuthorization, which
# reads as the more meaningful landmark but is absent whenever config.hosts is empty
# (the test environment), and anchoring there fails the boot outright. Sendfile is
# unconditional and sits immediately after host authorization, so on a deployed app
# this lands in exactly that slot: an allowlisted alias is redirected, while a forged
# Host header is refused before it gets here. Nothing about the redirect depends on
# that ordering for safety — the Location host is always the configured canonical one
# and never anything the request supplied.
#
# Required rather than autoloaded: `middleware` is on the autoload_lib ignore list in
# config/application.rb, so this is the single place the constant is defined.
require Rails.root.join("lib/middleware/canonical_host")

Rails.application.config.middleware.insert_before Rack::Sendfile, CanonicalHost
