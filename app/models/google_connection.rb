# A Google account the hub reads with a person's own sign-in: the `sign_in`
# connection method of config/integrations.yml. One sign-in, many abilities:
# each of ABILITIES is one read scope (Calendar, Gmail, Drive), asked for on
# its own from its /integrations card or the /admin/google page, and Google
# adds it to the account's grant (incremental consent). Nothing is copied by
# hand and no token is ever shown.
#
# One row per Google account (email, unique). Signing the same account in
# again replaces its token and adds the newly granted scopes to the ones it
# already had; `scope` is Google's own space-separated grant. The refresh
# token is encrypted at rest (Active Record Encryption, as TiktokConnection's
# is) and masked in every inspect.
#
# Until 2026-10-14 this was GoogleCalendarConnection (google_calendar_connections);
# the rename kept every row and token.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS. Without them nothing can be
# stored, so the sign-in refuses before it asks Google for anything. With them
# lost or changed, a stored row can no longer be read (#readable? is false): it
# counts as not connected, and signing in again replaces it.
class GoogleConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV

  # Every sign-in asks who the account is, plus the one ability's read scope.
  IDENTITY_SCOPES = %w[openid email].freeze
  # Each ability and the one read-only scope that unlocks it. None can write.
  ABILITIES = {
    calendar: "https://www.googleapis.com/auth/calendar.events.readonly",
    gmail: "https://www.googleapis.com/auth/gmail.readonly",
    drive: "https://www.googleapis.com/auth/drive.readonly"
  }.freeze
  ABILITY_NAMES = { calendar: "Google Calendar", gmail: "Gmail", drive: "Google Drive" }.freeze

  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :email, presence: true, uniqueness: true
  validates :refresh_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The ability named by a param or a symbol, or nil when it is not one.
    def ability(value) = ABILITIES.key?(value.to_s.to_sym) ? value.to_s.to_sym : nil

    def scope_for(ability) = ABILITIES.fetch(ability.to_sym)

    # The most recently connected account.
    def current = order(connected_at: :desc, id: :desc).first

    # The readable connection that grants `ability`, most recent first; nil when none does.
    def for(ability)
      order(connected_at: :desc, id: :desc).find { |connection| connection.readable? && connection.can?(ability) }
    end

    # Stores the account a sign-in connected. `grant` is the token endpoint's
    # JSON; `email` is the account it names. Its scopes are added to the ones
    # the row already had. Raises RecordInvalid when the answer lacks the
    # refresh token; the message names the field, never a value.
    def store!(grant, email:, by:, now: Time.current)
      transaction(requires_new: true) do
        connection = find_or_initialize_by(email: email.to_s.downcase)
        # A row whose token can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(email: connection.email)
        end
        granted = (connection.scopes | grant["scope"].to_s.split).join(" ").presence
        connection.assign_attributes(refresh_token: grant["refresh_token"].to_s, scope: granted, connected_by: by, connected_at: now)
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

  # The granted scope as names (Google writes one space-separated string).
  def scopes = scope.to_s.split

  # Did Google grant this ability's read? A person can untick it on the consent screen.
  def can?(ability) = scopes.include?(self.class.scope_for(ability))

  # The abilities this connection grants, in ABILITIES order.
  def abilities = ABILITIES.keys.select { can?(_1) }

  # Forgets one ability here and keeps the token for the others. Google cannot
  # revoke a single scope, so the grant itself still holds it until the last
  # ability goes (then the caller revokes the token and deletes the row).
  def drop!(ability)
    update!(scope: (scopes - [ self.class.scope_for(ability) ]).join(" ").presence)
  end
end
