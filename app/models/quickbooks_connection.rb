# A QuickBooks Online company the hub reads with a person's own Intuit sign-in:
# the `sign_in` connection method of config/integrations.yml, on the QuickBooks
# card of /integrations and the /admin/quickbooks page. One ability: read the
# company's info and its reports (scope com.intuit.quickbooks.accounting, used
# read only: Quickbooks::Reader holds no write path). No token is ever shown.
#
# One row per company (`realm_id`, Intuit's company id, unique): an owner can
# connect several companies, say a new file and read-only history in an older
# one. Signing the same company in again replaces its token (#store!).
# `environment` is the Intuit environment the company lives in (sandbox or
# production), fixed at sign-in, so the Reader calls the matching API host.
#
# INTUIT ROTATES REFRESH TOKENS. A refresh may answer a new refresh token, and
# Intuit says to always keep the one its latest answer gave (the previous one
# lapses about a day later). So a refresh happens only under this row's lock,
# and the answered token is stored (#rotate!) before the access token it came
# with is used (Quickbooks::OAuthClient.access_token). The stored token also
# lapses on its own: refresh_token_expires_at is the expiry Intuit stated.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS, as FathomConnection's does:
# without them the sign-in refuses before it asks Intuit for anything; with
# them lost or changed, a stored row is unreadable (#readable? is false),
# counts as not connected, and signing in again replaces it.
class QuickbooksConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV
  ENVIRONMENTS = %w[sandbox production].freeze
  # The company name when Intuit's CompanyInfo does not say.
  LABEL = "QuickBooks company".freeze

  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :realm_id, presence: true, uniqueness: true
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :refresh_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    def ordered = order(connected_at: :desc, id: :desc)

    # Every connected company whose token this server can read, newest first.
    def readable = ordered.select(&:readable?)

    # Stores the company a sign-in connected. `grant` is the token endpoint's
    # JSON; `realm_id` came on the callback. Raises RecordInvalid when the
    # answer lacks the refresh token; the message names the field, never a value.
    def store!(grant, realm_id:, company_name:, environment:, by:, now: Time.current)
      transaction(requires_new: true) do
        connection = find_or_initialize_by(realm_id: realm_id.to_s.strip)
        # A row whose token can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(realm_id: connection.realm_id)
        end
        connection.assign_attributes(refresh_token: grant["refresh_token"].to_s, company_name: company_name.to_s.strip.presence || LABEL,
                                     environment: environment.to_s, connected_by: by, connected_at: now, last_refreshed_at: nil,
                                     refresh_token_expires_at: expiry(grant, now))
        connection.save!
        connection
      end
    end

    # When the refresh token in `grant` lapses: Intuit's x_refresh_token_expires_in
    # (seconds), nil when it does not say.
    def expiry(grant, now)
      seconds = Integer(grant["x_refresh_token_expires_in"], exception: false)
      seconds&.positive? ? now + seconds.seconds : nil
    end
  end

  # Can the stored refresh token be decrypted with this app's keys?
  def readable?
    refresh_token
    true
  rescue ActiveRecord::Encryption::Errors::Base
    false
  end

  def sandbox? = environment == "sandbox"

  # Stores the refresh token a refresh just answered (the same one or a new
  # one), with its stated expiry. Called inside #with_lock by
  # Quickbooks::OAuthClient.access_token, before the access token is used. A
  # blank token is refused: storing it would lose the company.
  def rotate!(grant, now: Time.current)
    new_refresh_token = grant["refresh_token"]
    raise ArgumentError, "Intuit answered a refresh with no refresh token" if new_refresh_token.blank?

    update!(refresh_token: new_refresh_token, last_refreshed_at: now,
            refresh_token_expires_at: self.class.expiry(grant, now) || refresh_token_expires_at)
  end
end
