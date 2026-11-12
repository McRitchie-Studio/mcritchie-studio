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
# /admin/google shows. Agents read the HOUSEHOLD (.for, .current and every
# agent-side lookup start from .household) with ONE exception: the agent
# answering an owner in their own chat reads THAT owner's own rows (.owned_by,
# through GoogleConnect::OwnerContext, gated in AgentMessages::MemoryBundle):
# a client app's owner on their own app's CTO thread
# (/tasks/agent-reads-owner-google). No agent reads one user's rows for another
# user. A promoted user's rows join the household; a demoted admin's
# leave it. Each page says who reads a connection beside it (#who_reads). An account another user already connected is refused
# (TakenByAnotherUser), never taken over.
#
# DRIVE IS FILES YOU PICK, AND FILES THE HUB MAKES (/tasks/drive-files-you-pick,
# /tasks/drive-filing). The drive ability asks for drive.file, under which
# Google lets the app open only the files the person chose in the Google
# Picker, and the folders and files the app itself created. The hub READS the
# picked files (DriveReader) and WRITES only new folders and files of its own
# (GoogleConnect::DriveFiler through bin/drive, on request: make a folder path,
# upload a document, file a Gmail attachment). Everything it makes carries an
# appProperty mark and every lookup asks for it, so it reuses only its own
# folders; it never changes, shares or deletes a file, and each write logs a
# DriveFiling. No new scope: a connection made before drive-filing writes too. Each choice is a
# GoogleDrivePick on the connection (#drive_picks). A row connected before the
# change still holds drive.readonly (LEGACY_SCOPES): it keeps reading as it did,
# and its card says to reconnect to choose files. Reconnecting Drive swaps the
# legacy scope for drive.file here (.store_once!); nothing ever moves a row the
# other way. Google itself keeps the old drive.readonly grant on the token
# (include_granted_scopes), so the HUB'S rule is what narrows a reconnected
# row: every Drive read goes through DriveReader#files, which reads only the
# picked files for a drive.file row. Removing the old grant at Google takes
# the person at myaccount.google.com/permissions (the card and privacy page say so).
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
  # the files the person picks (#drive_picks), and writes only new folders and
  # files of its own, on request (GoogleConnect::DriveFiler, /tasks/drive-filing).
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
  # THE WRITE ABILITIES (/tasks/gmail-organize-ability): opt-in, each asked for
  # on its own from its own Connect, never by Connect Google (ALL), and never
  # read into an agent's chat context (GoogleConnect::OwnerContext walks
  # ABILITIES only). gmail_organize asks for two scopes and counts as granted
  # only when Google granted both: gmail.modify (read, label, archive, mark
  # read or unread, spam, Trash) and gmail.settings.basic (filters).
  # GOOGLE'S GRANT IS WIDER THAN THE HUB'S USE: gmail.modify also lets an app
  # compose and send, and Google's consent screen says so. The hub never sends:
  # that is a property of the source, enforced by test/lib/no_gmail_send_test.rb,
  # as it is for gmail.compose. Neither scope deletes forever, and the hub
  # moves nothing to Trash: GoogleConnect::GmailEditor has no such action.
  WRITE_ABILITIES = {
    gmail_organize: %w[https://www.googleapis.com/auth/gmail.modify
                       https://www.googleapis.com/auth/gmail.settings.basic]
  }.freeze
  # Every ability a Connect may name, read and write: ability => [scopes].
  ALL_ABILITIES = ABILITIES.transform_values { [ _1 ] }.merge(WRITE_ABILITIES).freeze
  ABILITY_NAMES = { calendar: "Google Calendar", gmail: "Gmail", drive: "Google Drive", gmail_organize: "Gmail organize" }.freeze
  # The `ability` param of Connect Google: every READ ability in one consent.
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

    # The ability named by a param or a symbol, read or write, or nil when it is not one.
    def ability(value) = ALL_ABILITIES.key?(value.to_s.to_sym) ? value.to_s.to_sym : nil

    # The abilities a Connect asks for: every one for ALL, else the one it
    # names; nil when the param is neither.
    def abilities_for(value)
      return ABILITIES.keys if value.to_s == ALL

      ability(value)&.then { [ _1 ] }
    end

    # A read ability's one scope.
    def scope_for(ability) = ABILITIES.fetch(ability.to_sym)

    # Every scope an ability asks for: one for a read ability, two for gmail_organize.
    def scopes_for(ability) = ALL_ABILITIES.fetch(ability.to_sym)

    # The household's connections: those an admin owns. The rows the hub's
    # agents and the /admin/google page read (an app owner's own: .owned_by).
    def household = joins(:user).merge(User.where(role: "admin"))

    # One user's own connections, and nobody else's: the rows the agent
    # answering that user in their own chat may read (GoogleConnect::OwnerContext).
    def owned_by(user) = where(user_id: user.id)

    # Newest first, the order every "which connection" answer reads in.
    def newest_first = order(connected_at: :desc, id: :desc)

    # The household's most recently connected account.
    def current = household.newest_first.first

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
    #
    # TWO SIGN-INS AT ONCE of the same new account (two tabs, a double click)
    # both find no row; the second insert then meets the unique email index
    # (RecordNotUnique), or its uniqueness validation sees the first's row.
    # store! looks again ONCE: the row is there now, so the same user's sign-in
    # merges into it and another user's is refused (TakenByAnotherUser). One
    # row either way; a second collision raises for the caller to answer.
    def store!(grant, email:, user:, abilities:, now: Time.current)
      looked_again = false
      begin
        store_once!(grant, email:, user:, abilities:, now:)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise if looked_again || (e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:email, :taken))

        looked_again = true
        retry
      end
    end

    # The account's row, locked for this sign-in, or a new one. The seam a
    # test races (google_connection_test: two sign-ins at once).
    def row_for_update(email) = lock.find_or_initialize_by(email:)

    # The household's readable connection that grants `ability`, most recent
    # first; nil when none does. Never a non-admin's row.
    def for(ability)
      household.newest_first.find { |connection| connection.readable? && connection.can?(ability) }
    end

    # The scopes an ability was granted under before it narrowed (LEGACY_SCOPES).
    def legacy_scopes_for(ability) = LEGACY_SCOPES.fetch(ability.to_sym, [])

    # The abilities among `abilities` whose every scope the grant carries.
    def granted_abilities(grant, abilities)
      scopes = grant["scope"].to_s.split
      abilities.map(&:to_sym).select { (scopes_for(_1) - scopes).empty? }
    end

    private

    def store_once!(grant, email:, user:, abilities:, now:)
      transaction(requires_new: true) do
        connection = row_for_update(email.to_s.downcase)
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

    # The grant's scopes, less every ability scope this sign-in did not ask
    # for and every legacy scope: include_granted_scopes echoes an old
    # drive.readonly grant, and taking it would widen a row past what was asked.
    def granted_scopes(grant, abilities)
      unasked = ALL_ABILITIES.values.flatten - abilities.flat_map { scopes_for(_1) }
      grant["scope"].to_s.split - unasked - LEGACY_SCOPES.values.flatten
    end
  end

  # WHO READS IT, the one rule every page's "who reads this" line comes from
  # (#who_reads), mirroring the agent side's gate
  # (AgentMessages::MemoryBundle#google_owner_context):
  #   :agents     an admin's row, the household's: the hub souls read it for
  #               an admin (.household, GoogleConnect::OwnerContext.household)
  #   :app_agent  a client app owner's own row (an owner AppMembership): their
  #               app's CTO reads it when they chat with it on their app's own
  #               thread (.owned_by, OwnerContext.for_user), and nobody else
  #   :owner      anyone else's: no agent reads it
  # A rule change on the agent side changes this predicate and its copy here.
  WHO_READS = {
    agents: "Your agents can read this",
    app_agent: "Your app's agent can read this when you chat with it",
    owner: "Only you can see this"
  }.freeze

  # Do the household's agents read it (an admin's row)?
  def agents_read? = user&.admin? == true

  # :agents, :app_agent or :owner, the key of WHO_READS.
  def reader
    return :agents if agents_read?
    return :app_agent if user&.slug.present? && AppMembership.owners.exists?(user_slug: user.slug)

    :owner
  end

  def who_reads = WHO_READS.fetch(reader)

  # Who a picked Drive file is shared with, in the Drive card's words, from the
  # same rule as #who_reads; nil when no agent reads this connection.
  DRIVE_AUDIENCE = { agents: "your agents", app_agent: "your app's agent" }.freeze
  # What a drive.file connection lets agents write, on the Drive card
  # (integrations/_drive_picks): GoogleConnect::DriveFiler's rules, in plain words.
  DRIVE_FILING = "On your request, agents may also create folders in your Drive and file documents there. " \
                 "They see only what they create, and never change, share or delete a file.".freeze
  def drive_audience = DRIVE_AUDIENCE[reader]

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
  # A write ability counts only when every one of its scopes is held.
  def can?(ability)
    (self.class.scopes_for(ability) - scopes).empty? || scopes.intersect?(self.class.legacy_scopes_for(ability))
  end

  # Does this row hold the ability only under its old, wider scope (Drive's
  # drive.readonly)? Such a row reads as it always did until it reconnects.
  def legacy?(ability)
    !scopes.include?(self.class.scope_for(ability)) && scopes.intersect?(self.class.legacy_scopes_for(ability))
  end

  # Does Drive read only the files picked for this row (drive.file)?
  def drive_picked? = scopes.include?(self.class.scope_for(:drive))

  # The abilities this connection grants, read and write, in ALL_ABILITIES order.
  def abilities = ALL_ABILITIES.keys.select { can?(_1) }

  # Forgets one ability here and keeps the token for the others. Google cannot
  # revoke a single scope, so the grant itself still holds it until the last
  # ability goes (then the caller revokes the token and deletes the row).
  # Dropping Drive forgets its picks too.
  def drop!(ability)
    transaction do
      drive_picks.delete_all if ability.to_sym == :drive
      update!(scope: (scopes - [ *self.class.scopes_for(ability), *self.class.legacy_scopes_for(ability) ]).join(" ").presence)
    end
  end
end
