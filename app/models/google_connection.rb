# A Google account the hub reads with a person's own sign-in: the `sign_in`
# connection method of config/integrations.yml. One sign-in, many abilities:
# each of ABILITIES is one scope (Calendar, Gmail, Drive), asked for on
# its own from its /integrations card or the /admin/google page, or all three
# at once from Connect Google (ALL), and Google adds it to the account's grant
# (incremental consent). Nothing is copied by hand and no token is ever shown.
#
# One row per Google account (email, unique). Signing the same account in
# again replaces its token and adds the scopes THAT sign-in asked for and
# Google granted to the ones it already had (#store!); `scope` is the
# space-separated grant as this hub counts it. The refresh
# token is encrypted at rest (Active Record Encryption, as TiktokConnection's
# is) and masked in every inspect.
#
# OWNERSHIP (/tasks/every-user-connects-google). Every row belongs to the user
# who signed it in (user_id). Any signed-in user may connect their own account
# from /integrations; an admin's connections are the HOUSEHOLD's, the ones
# /admin/google shows. AGENTS READ ONLY THE HOUSEHOLD: .for, .current and every
# agent-side lookup start from .household, so a viewer's connection is never
# agent input. A promoted user's rows join the household; a demoted admin's
# leave it. An account another user already connected is refused
# (TakenByAnotherUser), never taken over.
#
# DRIVE IS FILES YOU PICK (/tasks/drive-files-you-pick). The drive ability
# asks for drive.file, under which Google lets the app open only the files the
# person chose in the Google Picker (or files the app made). Each choice is a
# GoogleDrivePick on the connection (#drive_picks). A row connected before the
# change still holds drive.readonly (LEGACY_SCOPES): it keeps reading as it did,
# and its card says to reconnect to choose files. Reconnecting Drive swaps the
# legacy scope for drive.file here; nothing ever moves a row the other way.
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
  # Each ability and the one scope a sign-in asks for to unlock it. Calendar
  # and Gmail are read-only scopes. Drive's is drive.file: the hub reads only
  # the files the person picks (#drive_picks), and writes nothing.
  ABILITIES = {
    calendar: "https://www.googleapis.com/auth/calendar.events.readonly",
    gmail: "https://www.googleapis.com/auth/gmail.readonly",
    drive: "https://www.googleapis.com/auth/drive.file"
  }.freeze
  # Scopes an ability was granted under before it narrowed. Never asked for
  # again; a row holding one still counts as granting the ability (#can?) and
  # reads the way it always did (#legacy?).
  LEGACY_SCOPES = {
    drive: %w[https://www.googleapis.com/auth/drive.readonly]
  }.freeze
  ABILITY_NAMES = { calendar: "Google Calendar", gmail: "Gmail", drive: "Google Drive" }.freeze
  # The `ability` param of Connect Google: every ability in one consent.
  ALL = "all".freeze

  # A sign-in of an account another user already connected.
  class TakenByAnotherUser < StandardError
    def initialize(msg = "That Google account is already connected by another user.") = super
  end

  belongs_to :user
  # The Drive files picked for this connection. The foreign key cascades too,
  # since a disconnect deletes the row with delete_all.
  has_many :drive_picks, class_name: "GoogleDrivePick", inverse_of: :google_connection, dependent: :delete_all

  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :email, presence: true, uniqueness: true
  validates :refresh_token, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The ability named by a param or a symbol, or nil when it is not one.
    def ability(value) = ABILITIES.key?(value.to_s.to_sym) ? value.to_s.to_sym : nil

    # The abilities a Connect asks for: every one for ALL, else the one it
    # names; nil when the param is neither.
    def abilities_for(value)
      return ABILITIES.keys if value.to_s == ALL

      ability(value)&.then { [ _1 ] }
    end

    def scope_for(ability) = ABILITIES.fetch(ability.to_sym)

    # The household's connections: those an admin owns. The only rows agents
    # and the /admin/google page read.
    def household = joins(:user).merge(User.where(role: "admin"))

    # Newest first, the order every "which connection" answer reads in.
    def newest_first = order(connected_at: :desc, id: :desc)

    # The household's most recently connected account.
    def current = household.newest_first.first

    # The household's readable connection that grants `ability`, most recent
    # first; nil when none does. Never a non-admin's row.
    def for(ability)
      household.newest_first.find { |connection| connection.readable? && connection.can?(ability) }
    end

    # Stores the account a sign-in connected, owned by `user`. `grant` is the
    # token endpoint's JSON; `email` is the account it names; `abilities` are the ones THIS
    # sign-in asked for. The row keeps the scopes it already had and adds the
    # granted scopes of the asked-for abilities, and no other ability's:
    # include_granted_scopes makes Google echo every scope the account ever
    # granted, so an ability disconnected here (#drop!) would otherwise come
    # back when another one connects. Raises RecordInvalid when the answer
    # lacks the refresh token; the message names the field, never a value.
    # Raises TakenByAnotherUser, storing nothing, when another user owns the
    # account's row (readable or not): no silent takeover.
    def store!(grant, email:, user:, abilities:, now: Time.current)
      transaction(requires_new: true) do
        connection = lock.find_or_initialize_by(email: email.to_s.downcase)
        raise TakenByAnotherUser if connection.persisted? && connection.user_id != user.id
        # A row whose token can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(email: connection.email)
        end
        # A sign-in that asks for an ability retires its legacy scope here.
        kept = connection.scopes - abilities.flat_map { legacy_scopes_for(_1) }
        granted = (kept | granted_scopes(grant, abilities)).join(" ").presence
        connection.assign_attributes(refresh_token: grant["refresh_token"].to_s, scope: granted, user:, connected_by: user.slug, connected_at: now)
        connection.save!
        connection
      end
    end

    def legacy_scopes_for(ability) = LEGACY_SCOPES.fetch(ability.to_sym, [])

    # The abilities among `abilities` whose scope the grant carries.
    def granted_abilities(grant, abilities)
      scopes = grant["scope"].to_s.split
      abilities.map(&:to_sym).select { scopes.include?(scope_for(_1)) }
    end

    private

    # The grant's scopes, less every ability scope this sign-in did not ask
    # for and every legacy scope: include_granted_scopes echoes an old
    # drive.readonly grant, and taking it would widen a row past what was asked.
    def granted_scopes(grant, abilities)
      unasked = ABILITIES.values - abilities.map { scope_for(_1) }
      grant["scope"].to_s.split - unasked - LEGACY_SCOPES.values.flatten
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

  # Did Google grant this ability? A person can untick it on the consent
  # screen. A legacy scope counts (#legacy?).
  def can?(ability) = scopes.intersect?([ self.class.scope_for(ability), *self.class.legacy_scopes_for(ability) ])

  # Does this row hold the ability only under its old, wider scope (Drive's
  # drive.readonly)? Such a row reads as it always did until it reconnects.
  def legacy?(ability)
    !scopes.include?(self.class.scope_for(ability)) && scopes.intersect?(self.class.legacy_scopes_for(ability))
  end

  # Does Drive read only the files picked for this row (drive.file)?
  def drive_picked? = scopes.include?(self.class.scope_for(:drive))

  # The abilities this connection grants, in ABILITIES order.
  def abilities = ABILITIES.keys.select { can?(_1) }

  # Forgets one ability here and keeps the token for the others. Google cannot
  # revoke a single scope, so the grant itself still holds it until the last
  # ability goes (then the caller revokes the token and deletes the row).
  # Dropping Drive forgets its picks too.
  def drop!(ability)
    transaction do
      drive_picks.delete_all if ability.to_sym == :drive
      update!(scope: (scopes - [ self.class.scope_for(ability), *self.class.legacy_scopes_for(ability) ]).join(" ").presence)
    end
  end
end
