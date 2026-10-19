# frozen_string_literal: true

# Mount the shared client-app host (lib/middleware/client_app_host.rb;
# docs/agents/system/client-app-host.md): a request for <sub>.<preview domain> is
# answered from the app's static bundle and never reaches the hub.
#
# Anchored BEFORE CanonicalHost, which would otherwise 301 every preview host to
# mcritchie.studio, and so after EdgeGuard and host authorization (production
# lists the preview domain in config.hosts). Everything that could write a cookie
# or answer as the hub (Cookies, the session, Flash, CSP, Rack::Attack, OmniAuth,
# the routes) sits behind it, and a preview request never reaches them.
#
# Required rather than autoloaded: `middleware` is on the autoload_lib ignore
# list in config/application.rb.
require Rails.root.join("lib/middleware/client_app_host")

Rails.application.config.middleware.insert_before CanonicalHost, ClientAppHost
