# frozen_string_literal: true

# CanonicalHost — one front door, so a sign-in cannot start on a hostname Google has
# never been told about.
#
# This app answers on several names at once. `APP_HOST_ALIASES` allowlists
# `www.mcritchie.studio` and the legacy `app.mcritchie.studio` beside the canonical
# apex, and every one of them served the full application with no redirect between
# them. That is invisible until an OAuth handshake starts, because omniauth builds its
# `redirect_uri` from the host the REQUEST arrived on: begin on `www.` and Google is
# handed `https://www.mcritchie.studio/auth/google_oauth2/callback`, which is not on
# the OAuth client's authorized list, and answers `Error 400: redirect_uri_mismatch`.
#
# Measured 2026-09-19 against production — three hosts, three different `redirect_uri`
# values, one registered. The failure reads as account-specific (it follows whichever
# browser profile happens to hold the `www.` bookmark) which is exactly the wrong
# place to look, so the cure is structural: collapse the front doors to one.
#
# The two halves are deliberately one class. The middleware moves BROWSERS onto the
# canonical host, and `.origin` hands `config/initializers/omniauth.rb` the same
# answer to pin the callback to. Splitting them is how they drift, and a callback
# origin that disagrees with the front door reintroduces precisely this bug.
#
# Dark by default. `APP_HOST` is set only on a deployed app, so locally and in test
# this is a complete pass-through. Never redirect at a GUESSED canonical host: a wrong
# 301 is the one failure here a visitor's own browser would keep repeating.
class CanonicalHost
  # Heroku's platform health check reaches the dyno directly, by its own hostname and
  # with no vanity name in front. Redirecting it would fail the check rather than
  # canonicalize anything. Kept in step with EdgeGuard::EXEMPT_PATHS and
  # config.host_authorization's exclusion in production.rb.
  EXEMPT_PATHS = ["/up"].freeze

  # Only navigation is moved. A 301 rewrites POST to GET in browsers and is ignored
  # outright by plenty of API clients, so redirecting anything else would quietly
  # corrupt webhook deliveries and /api/v1 calls that happen to name an alias.
  # Those still reach the app; the pinned OAuth origin is what covers the one POST
  # that matters here (the omniauth request phase).
  REDIRECTABLE_METHODS = %w[GET HEAD].freeze

  DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

  class << self
    # The canonical hostname for THIS deploy target, or nil where none is configured.
    # Production defaults it to the public apex; QA apps set it to their own domain
    # (config/qa_environments.yml), which is why this is read rather than hardcoded.
    def host(env = ENV)
      normalize(env["APP_HOST"])
    end

    # The origin omniauth pins its callback to. https is not a guess: APP_HOST is set
    # only on deployed apps, and every one of them runs with config.force_ssl.
    def origin(env = ENV)
      canonical = host(env)
      canonical && "https://#{canonical}"
    end

    # Hosts that must stay reachable under their own name. The dyno's direct hostname
    # is allowlisted on purpose (health checks, internal tooling) — see EdgeGuard for
    # what actually keeps strangers off it.
    def direct_hosts(env = ENV)
      env["DYNO_HOST"].to_s.split(",").filter_map { |entry| normalize(entry) }
    end

    # Tolerate an APP_HOST written as a URL. Operators set these by hand in `heroku
    # config:set`, and a stray scheme or trailing slash would otherwise build a
    # Location header that redirects to nowhere.
    def normalize(value)
      value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").sub(%r{/+\z}, "").presence
    end
  end

  def initialize(app, canonical_host: self.class.host, direct_hosts: self.class.direct_hosts)
    @app = app
    @canonical_host = self.class.normalize(canonical_host)
    @direct_hosts = Array(direct_hosts).filter_map { |entry| self.class.normalize(entry) }.freeze
  end

  def call(env)
    return @app.call(env) if @canonical_host.nil?

    request = Rack::Request.new(env)
    return @app.call(env) unless redirectable?(request)

    redirect_to(canonical_url(request))
  end

  private

  def redirectable?(request)
    return false unless REDIRECTABLE_METHODS.include?(request.request_method)
    return false if EXEMPT_PATHS.include?(request.path)

    host = request.host.to_s.downcase
    return false if host.empty? || host == @canonical_host

    @direct_hosts.exclude?(host)
  end

  # The scheme is carried rather than forced: config.force_ssl owns the http->https
  # upgrade, and quietly doing it here too would mask a misconfigured one.
  def canonical_url(request)
    url = +"#{request.scheme}://#{@canonical_host}"
    url << ":#{request.port}" unless request.port == DEFAULT_PORTS[request.scheme]
    url << request.fullpath
    url
  end

  # 301, because these aliases are permanent (app.mcritchie.studio is documented as a
  # legacy alias) and search engines should consolidate on the apex. The short max-age
  # is the reversibility valve: a 301 is otherwise cached by a browser indefinitely,
  # so a canonical host that ever went out wrong would be unreachable-by-cache long
  # after the config was fixed.
  #
  # Header names are lowercase per the Rack 3 SPEC.
  def redirect_to(url)
    [301,
     { "location" => url,
       "content-type" => "text/html; charset=utf-8",
       "cache-control" => "max-age=3600" },
     [%(<html><body>Moved to <a href="#{Rack::Utils.escape_html(url)}">#{Rack::Utils.escape_html(url)}</a>.</body></html>\n)]]
  end
end
