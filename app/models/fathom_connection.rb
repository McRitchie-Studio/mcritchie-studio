# A Fathom account the hub reads with a person's own sign-in: the `sign_in`
# connection method of config/integrations.yml, on the Fathom card of
# /integrations and the /admin/fathom page. One ability: read meeting notes and
# transcripts (Fathom's one OAuth scope, public_api). No token is ever shown.
#
# One row per Fathom account (`account`, unique): the recorder's email when
# Fathom's meeting list names one at sign-in, else LABEL. Signing the same
# account in again replaces its token (#store!).
#
# FATHOM REFRESH TOKENS ARE SINGLE-USE. Every refresh answers a new refresh
# token, and the old one stops working at that moment. So a refresh happens
# only under this row's lock, and the new token is stored (#rotate!) before
# the access token it came with is used (Fathom::OAuthClient.access_token). Two
# refreshes racing on one token would burn it and disconnect the account.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS, as GoogleConnection's does:
# without them the sign-in refuses before it asks Fathom for anything; with
# them lost or changed, a stored row is unreadable (#readable? is false), counts
# as not connected, and signing in again replaces it.
class FathomConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV
  # The account name when Fathom's API does not say who signed in.
  LABEL = "Fathom account".freeze

  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :account, presence: true, uniqueness: true
  validates :refresh_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The most recently connected account.
    def current = order(connected_at: :desc, id: :desc).first

    # The most recently connected account whose token this server can read; nil when none.
    def readable = order(connected_at: :desc, id: :desc).find(&:readable?)

    # Stores the account a sign-in connected. `grant` is the token endpoint's
    # JSON; `account` names who signed in (LABEL when unknown). Raises
    # RecordInvalid when the answer lacks the refresh token; the message names
    # the field, never a value.
    def store!(grant, account:, by:, now: Time.current)
      transaction(requires_new: true) do
        connection = find_or_initialize_by(account: account.to_s.strip.downcase.presence || LABEL.downcase)
        # A row whose token can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(account: connection.account)
        end
        connection.assign_attributes(refresh_token: grant["refresh_token"].to_s, connected_by: by, connected_at: now, last_refreshed_at: nil)
        connection.save!
        connection
      end
    end
  end

  # Can the stored refresh token be decrypted with this app's keys?
  def readable?
    refresh_token
    true
  rescue ActiveRecord::Encryption::Errors::Base
    false
  end

  # Stores the refresh token a refresh just answered, replacing the spent one.
  # Called inside #with_lock by Fathom::OAuthClient.access_token, before the
  # access token is used. A blank token is refused: storing it would lose the
  # account, while the old one is at worst already spent.
  def rotate!(new_refresh_token, now: Time.current)
    raise ArgumentError, "Fathom answered a refresh with no new refresh token" if new_refresh_token.blank?

    update!(refresh_token: new_refresh_token, last_refreshed_at: now)
  end
end
