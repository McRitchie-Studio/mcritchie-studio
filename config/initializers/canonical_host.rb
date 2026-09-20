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
# unconditional and sits just past host authorization, so on a deployed app this lands
# after BOTH of the gates that matter — host authorization, and the ActionDispatch::SSL
# that config.force_ssl inserts between them. Each is the right side to be on: a forged
# Host header is refused rather than redirected, and http has already been upgraded, so
# the scheme carried into the Location is the real one. Nothing about the redirect
# depends on that ordering for safety, though — the Location host is always the
# configured canonical one and never anything the request supplied.
#
# Required rather than autoloaded: `middleware` is on the autoload_lib ignore list in
# config/application.rb, so this is the single place the constant is defined.
require Rails.root.join("lib/middleware/canonical_host")

Rails.application.config.middleware.insert_before Rack::Sendfile, CanonicalHost
