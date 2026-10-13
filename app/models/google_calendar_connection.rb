# A Google account whose calendar the hub reads: what
# /admin/google_calendar/callback stores when an admin finishes Google's
# sign-in, so no token is ever copied by hand or shown. This is the `sign_in`
# connection method of config/integrations.yml: one person, one click, and it
# may ask again (the person revokes it, or it goes unused for six months).
#
# One row per Google account (email, unique). Signing the same account in
# again replaces its token; the connection in use is .current, the one
# connected most recently. The refresh token is encrypted at rest (Active
# Record Encryption, as TiktokConnection's is) and masked in every inspect.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS. Without them nothing can be
# stored, so the sign-in refuses before it asks Google for anything. With them
# lost or changed, a stored row can no longer be read (#readable? is false): it
# counts as not connected, and signing in again replaces it.
class GoogleCalendarConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV

  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :email, presence: true, uniqueness: true
  validates :refresh_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The connection the hub reads: the most recently connected account.
    def current = order(connected_at: :desc, id: :desc).first

    # Stores the account a sign-in connected. `grant` is the token endpoint's
    # JSON; `email` is the account it names. Raises RecordInvalid when the
    # answer lacks the refresh token; the message names the field, never a value.
    def store!(grant, email:, by:, now: Time.current)
      transaction(requires_new: true) do
        connection = find_or_initialize_by(email: email.to_s.downcase)
        # A row whose token can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(email: connection.email)
        end
        connection.assign_attributes(refresh_token: grant["refresh_token"].to_s, scope: grant["scope"].to_s.presence,
                                     connected_by: by, connected_at: now)
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

  # Did Google grant the calendar read? A person can untick it on the consent
  # screen, and a connection without it reads nothing.
  def can_read_calendar? = scopes.include?(GoogleCalendar::OAuthClient::CALENDAR_SCOPE)
end
