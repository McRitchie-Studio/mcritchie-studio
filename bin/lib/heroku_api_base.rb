# frozen_string_literal: true

require "uri"

# The only places a Heroku bearer token may be sent: the real Platform API over
# TLS, or a loopback stand-in a test runs. Every token-bearing Heroku client that
# takes a base-URL override (bin/heroku-secret-set's HEROKU_API_BASE,
# bin/rotate-heroku-ci-key's ROTATE_HEROKU_CI_KEY_API_BASE) resolves it here, so
# a planted override cannot collect the token (secrets-scrub-follow-ups, N6).
module HerokuApiBase
  REAL = "https://api.heroku.com"
  LOOPBACK = %w[127.0.0.1 localhost ::1 [::1]].freeze

  class Refused < StandardError; end

  module_function

  # The base as a URI, or Refused naming why. `name` is the variable it came from.
  def resolve!(value, name:)
    uri = begin
      URI(value.to_s)
    rescue URI::InvalidURIError
      raise Refused, "#{name} is not a URL"
    end
    raise Refused, "#{name} may name only #{REAL} or a loopback http:// stand-in, so the token cannot be sent elsewhere" unless allowed?(uri)

    uri
  end

  def allowed?(uri)
    host = uri.host.to_s.downcase
    real = uri.scheme == "https" && host == "api.heroku.com" && uri.port == 443
    local = uri.scheme == "http" && LOOPBACK.include?(host)
    clean = uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && ["", "/"].include?(uri.path)
    (real || local) && clean
  end
end
