# frozen_string_literal: true

# THE SHARED CLIENT-APP HOST'S FRONT DOOR (docs/agents/system/client-app-host.md).
#
# Every /build app's first version is a static bundle served at
# <sub>.<preview domain> (mcritchie.si in production). The preview domain is a
# SEPARATE registrable domain, so the hub's `.mcritchie.studio` session cookie
# (config/initializers/session_store.rb) is never sent to model-written code.
#
# This middleware sits right after host authorization, in front of the canonical
# redirect, the cookie jar, the session, flash, CSRF, Rack::Attack, OmniAuth and
# the router. A request whose host is under the preview domain is answered HERE
# (ClientApps::Host) and never reaches any of them: so no Set-Cookie can be
# written, no session is read, and no hub route answers. Every other host passes
# through untouched.
#
# Required rather than autoloaded (`middleware` is on the autoload_lib ignore
# list): config/initializers/client_app_host.rb mounts it, and
# config/environments/production.rb reads .domain for config.hosts.
class ClientAppHost
  ENV_NAME = "CLIENT_APP_PREVIEW_DOMAIN"
  PRODUCTION_DOMAIN = "mcritchie.si"
  # Development and test: `localhost`, whose subdomains every browser (and
  # Playwright, and curl >= 7.85) resolves to loopback with no /etc/hosts edit:
  # http://demo.localhost:3038/.
  LOCAL_DOMAIN = "localhost"
  OFF = %w[off none false 0].freeze
  # The production session cookie's domain (config/initializers/session_store.rb):
  # a preview domain at or under it would hand model-written code the hub's cookies.
  HUB_COOKIE_DOMAIN = "mcritchie.studio"
  # One DNS label, as AppRequest::SUBDOMAIN_FORMAT spells a subdomain.
  LABEL = /\A[a-z0-9][a-z0-9-]{1,28}[a-z0-9]\z/

  class << self
    # The preview domain, or nil when the host is off.
    #
    #   CLIENT_APP_PREVIEW_DOMAIN set   that domain ("off" turns the host off)
    #   unset, production               mcritchie.si
    #   unset, QA (production + QA_ENV) off: a QA app never claims prod's domain
    #   unset, development or test      localhost
    def domain(env = ENV, production: Rails.env.production?, qa: qa_environment?)
      value = env[ENV_NAME].to_s.strip.downcase.delete_prefix(".")
      return nil if OFF.include?(value)
      if value == HUB_COOKIE_DOMAIN || value.end_with?(".#{HUB_COOKIE_DOMAIN}")
        raise ArgumentError, "#{ENV_NAME}=#{value} is inside the hub session cookie's domain; use a separate registrable domain"
      end
      return value unless value.empty?
      return (qa ? nil : PRODUCTION_DOMAIN) if production

      LOCAL_DOMAIN
    end

    # Whether HOST (no port) is on the preview domain: any subdomain of it, and
    # the apex too unless the apex is the hub itself (localhost in development).
    def preview_host?(host, domain)
      return false if domain.nil? || host.nil? || host.empty?

      host.end_with?(".#{domain}") || (host == domain && domain != LOCAL_DOMAIN)
    end

    # The app's sub for HOST, or nil when HOST is not exactly one valid label
    # under the domain (the apex, a nested name, a malformed label).
    def sub_for(host, domain)
      return nil unless preview_host?(host, domain) && host != domain

      label = host.delete_suffix(".#{domain}")
      label.match?(LABEL) ? label : nil
    end

    # Where SUB answers: https in production, http on the desk's port locally.
    def url_for(sub, domain: self.domain, env: ENV, production: Rails.env.production?)
      return nil if domain.nil?
      return "https://#{sub}.#{domain}" if production

      port = env["APP_PORT"].presence || env["PORT"].presence || "3000"
      "http://#{sub}.#{domain}:#{port}"
    end

    def qa_environment?
      defined?(Studio) && Studio.respond_to?(:qa_environment?) ? Studio.qa_environment? : false
    end

    # The request's host, lowercased, without port. Read from HTTP_HOST as Rack
    # does (SERVER_NAME when there is none).
    def request_host(env)
      raw = env["HTTP_HOST"].to_s.presence || env["SERVER_NAME"].to_s
      raw = raw.strip.downcase
      raw.start_with?("[") ? raw : raw.sub(/:\d+\z/, "")
    end

    # The hosts X-Forwarded-Host and Forwarded name. Rack, HostAuthorization and
    # the hub's request.host believe them, so a hub request naming a preview host
    # there is the door's (a 404: its sub comes only from HTTP_HOST), never the hub's.
    def forwarded_hosts(env)
      names = env["HTTP_X_FORWARDED_HOST"].to_s.split(",") + env["HTTP_FORWARDED"].to_s.scan(/host="?([^";,\s]+)/i).flatten
      names.map { |name| name.strip.downcase.sub(/:\d+\z/, "") }
    end
  end

  def initialize(app, domain: self.class.domain)
    @app = app
    @domain = domain
    # Text responses are compressed as the hub's own are (config/application.rb),
    # since this door is in front of the hub's Deflater.
    # A HEAD carries no body to compress.
    @preview = Rack::Deflater.new(method(:serve), if: ->(env, *) { env["REQUEST_METHOD"] != "HEAD" })
  end

  def call(env)
    host = self.class.request_host(env)
    forwarded = self.class.forwarded_hosts(env).any? { |name| self.class.preview_host?(name, @domain) }
    return @app.call(env) unless forwarded || self.class.preview_host?(host, @domain)

    env["client_app_host.sub"] = self.class.sub_for(host, @domain)
    @preview.call(env)
  end

  private

  # In front of ActionDispatch::Executor and the Reloader, so the database
  # connection and code reloading are wrapped here (the Reloader runs the
  # Executor too).
  def serve(env)
    Rails.application.reloader.wrap { ClientApps::Host.call(env, env["client_app_host.sub"]) }
  end
end
