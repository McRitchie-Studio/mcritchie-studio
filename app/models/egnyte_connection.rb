# An Egnyte domain the hub reads and writes with a person's own sign-in: the
# `sign_in` connection method of config/integrations.yml, on the Egnyte card of
# /integrations and the /admin/egnyte page. One scope, Egnyte.filesystem: list
# folders, read file metadata, upload a file. No token is ever shown.
#
# One row per Egnyte domain (`domain`, unique): the subdomain of
# <domain>.egnyte.com. Egnyte's Public API answers on each domain's own host
# (https://<domain>.egnyte.com/pubapi/...), so the domain is part of every
# request, and the admin names it before Connect. Signing the same domain in
# again replaces its tokens (#store!).
#
# TOKENS (Egnyte's authentication docs, read 2026-11-06). The access token
# lives 30 days (expires_in 2592000). A refresh answers a new access token AND
# a new refresh token, so the refresh token rotates. Egnyte asks callers to
# cache the access token (its token endpoint allows about 100 requests an hour
# per app), so this row keeps both tokens, encrypted, with the access token's
# expiry. Egnyte::OAuthClient.access_token refreshes only within REFRESH_MARGIN
# of that expiry (or after a 401), under this row's lock, and stores the new
# pair (#rotate!) before the access token is used. A grant with no expiry
# (expires_in -1 on an older key) is kept until Egnyte refuses it.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS, as FathomConnection's does:
# without them the sign-in refuses before it asks Egnyte for anything; with
# them lost or changed, a stored row is unreadable (#readable? is false),
# counts as not connected, and signing in again replaces it.
class EgnyteConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV
  # A DNS label: what may stand before .egnyte.com. Nothing else ever reaches a URL.
  DOMAIN_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  HOST_SUFFIX = ".egnyte.com".freeze
  # Refresh this long before the access token's expiry, not at the edge.
  REFRESH_MARGIN = 1.day

  encrypts :access_token, :refresh_token
  self.filter_attributes += %i[access_token refresh_token]

  validates :domain, presence: true, uniqueness: true, format: { with: DOMAIN_FORMAT }
  validates :access_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The bare domain from what an admin typed ("acme", "acme.egnyte.com",
    # "https://acme.egnyte.com/"), or nil when it is not one.
    def normalize_domain(value)
      host = value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").sub(%r{[/?#].*\z}, "").delete_suffix(HOST_SUFFIX)
      host.match?(DOMAIN_FORMAT) ? host : nil
    end

    # Every connected domain whose tokens this server can read, by domain.
    def readable = order(:domain).select(&:readable?)

    # Stores the domain a sign-in connected. `grant` is the token endpoint's
    # JSON; `username` is who signed in (nil when Egnyte did not say). Raises
    # RecordInvalid when the answer lacks the access token; the message names
    # the field, never a value.
    def store!(grant, domain:, username:, by:, now: Time.current)
      transaction(requires_new: true) do
        connection = find_or_initialize_by(domain: normalize_domain(domain) || domain.to_s)
        # A row whose tokens can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(domain: connection.domain)
        end
        connection.assign_attributes(access_token: grant["access_token"].to_s, refresh_token: grant["refresh_token"].presence,
                                     access_expires_at: expiry(grant, now), username: username.presence,
                                     connected_by: by, connected_at: now, last_refreshed_at: nil)
        connection.save!
        connection
      end
    end

    # When an access token from `grant` stops working: nil when Egnyte gave no
    # positive lifetime (an older key's -1 means it does not expire).
    def expiry(grant, now)
      seconds = Integer(grant["expires_in"].to_s, exception: false)
      seconds&.positive? ? now + seconds : nil
    end
  end

  def host = "#{domain}#{HOST_SUFFIX}"

  # Can the stored tokens be decrypted with this app's keys?
  def readable?
    access_token
    refresh_token
    true
  rescue ActiveRecord::Encryption::Errors::Base
    false
  end

  # Is the stored access token good for longer than the margin? A token with
  # no expiry is, until Egnyte refuses it.
  def access_fresh?(now = Time.current) = access_expires_at.nil? || access_expires_at > now + REFRESH_MARGIN

  # Stores the pair a refresh just answered. Called inside #with_lock by
  # Egnyte::OAuthClient.access_token, before the access token is used. A blank
  # access token is refused; a blank refresh token keeps the stored one (at
  # worst already spent, which the next refresh says plainly).
  def rotate!(grant, now: Time.current)
    raise ArgumentError, "Egnyte answered a refresh with no access token" if grant["access_token"].blank?

    update!(access_token: grant["access_token"], refresh_token: grant["refresh_token"].presence || refresh_token,
            access_expires_at: self.class.expiry(grant, now), last_refreshed_at: now)
  end
end
