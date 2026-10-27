require "test_helper"
require "support/google_connect_fakes"
require Rails.root.join("db/migrate/20261014203000_rename_google_calendar_connections_to_google_connections")
require Rails.root.join("db/migrate/20261024230000_add_user_to_google_connections")

# [unit] GoogleConnection: the Google account the hub reads, as the sign-in
# stores it, and the abilities its granted scopes unlock. Every token here is
# synthetic.
class GoogleConnectionTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  TOKEN = "1//synthetic-refresh-0001".freeze
  NOW = Time.utc(2026, 10, 13, 22, 0, 0)
  ALL = GoogleConnection::ABILITIES.keys

  def grant(**over) = token_grant(refresh_token: TOKEN, **over).transform_keys(&:to_s)
  def alex = users(:alex)
  def viewer = users(:viewer)

  test "[unit] the refresh token is ciphertext at rest and reads back in the clear" do
    connection = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW)
    raw = GoogleConnection.connection.select_value("SELECT refresh_token FROM google_connections WHERE id = #{connection.id}")

    assert raw.present?
    assert_not_includes raw, TOKEN
    assert_equal TOKEN, connection.reload.refresh_token
  end

  test "[unit] an inspect masks the refresh token" do
    connection = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW)

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, "user_id: #{alex.id}" # the control: inspect does print this row
  end

  test "[unit] signing the same account in again replaces its token, one row per account" do
    GoogleConnection.store!(grant, email: "Alex@McRitchie.studio", user: alex, abilities: ALL, now: NOW)
    second = GoogleConnection.store!(grant(refresh_token: "1//second"), email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW + 1.hour)

    assert_equal 1, GoogleConnection.count
    assert_equal "1//second", second.reload.refresh_token
    assert_equal second, GoogleConnection.current
  end

  test "[unit] current is the most recently connected account" do
    GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL, now: NOW)
    later = GoogleConnection.store!(grant, email: "b@example.com", user: alex, abilities: ALL, now: NOW + 1.minute)

    assert_equal later, GoogleConnection.current
  end

  test "[unit] an answer with no refresh token is refused by field name" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      GoogleConnection.store!(grant(refresh_token: nil), email: "alex@mcritchie.studio", user: alex, abilities: ALL)
    end
    assert_match(/Refresh token/, error.message)
  end

  test "[unit] connection records granted scopes and answers per ability" do
    calendar = GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL)
    unticked = GoogleConnection.store!(grant(scope: "openid email"), email: "b@example.com", user: alex, abilities: ALL)

    assert calendar.can?(:calendar)
    refute calendar.can?(:gmail)
    refute calendar.can?(:drive)
    assert_equal [ :calendar ], calendar.abilities
    assert_empty unticked.abilities
    assert_raises(KeyError) { calendar.can?(:contacts) }
  end

  test "[unit] a second sign-in adds its scope to the ones already granted, one row" do
    GoogleConnection.store!(grant, email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW)
    both = GoogleConnection.store!(grant(scope: "openid email #{DRIVE}", refresh_token: "1//drive"), email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW + 1.hour)

    assert_equal 1, GoogleConnection.count
    assert_equal %i[calendar drive], both.reload.abilities
    assert_equal "1//drive", both.refresh_token, "the newest token carries every granted scope"
  end

  test "[unit] store keeps only the scopes this sign-in asked for and Google granted" do
    # Google echoes Gmail and Drive (include_granted_scopes), but this sign-in asked for Calendar alone.
    row = GoogleConnection.store!(grant(scope: "openid email #{CALENDAR} #{GMAIL} #{DRIVE}"), email: "a@example.com", user: alex, abilities: [ :calendar ])

    assert_equal [ :calendar ], row.abilities
    assert_includes row.scopes, "openid", "identity scopes are kept"
  end

  test "[unit] store asking for every ability keeps the granted subset, not the unticked one" do
    row = GoogleConnection.store!(grant(scope: "openid email #{CALENDAR} #{DRIVE}"), email: "a@example.com", user: alex, abilities: ALL)

    assert_equal %i[calendar drive], row.abilities
  end

  test "[unit] a dropped scope stays dropped when another ability connects and Google echoes it" do
    row = GoogleConnection.store!(grant(scope: "openid email #{CALENDAR} #{GMAIL}"), email: "a@example.com", user: alex, abilities: %i[calendar gmail])
    row.drop!(:gmail)
    assert_equal [ :calendar ], row.reload.abilities # the control: the drop took

    echoed = "openid email #{CALENDAR} #{GMAIL} #{DRIVE}" # Google still holds Gmail, and says so
    after = GoogleConnection.store!(grant(scope: echoed, refresh_token: "1//drive"), email: "a@example.com", user: alex, abilities: [ :drive ])

    assert_equal %i[calendar drive], after.reload.abilities, "Gmail stays off"
  end

  test "[unit] granted_abilities answers the asked-for abilities the grant carries" do
    assert_equal %i[calendar drive], GoogleConnection.granted_abilities({ "scope" => "openid #{DRIVE} #{CALENDAR} #{GMAIL}" }, %i[calendar drive])
    assert_empty GoogleConnection.granted_abilities({ "scope" => "openid email" }, ALL)
  end

  test "[unit] abilities_for reads one ability, all of them, or nothing" do
    assert_equal [ :gmail ], GoogleConnection.abilities_for("gmail")
    assert_equal %i[calendar gmail drive], GoogleConnection.abilities_for(GoogleConnection::ALL)
    assert_nil GoogleConnection.abilities_for("contacts")
    assert_nil GoogleConnection.abilities_for(nil)
  end

  test "[unit] drop! forgets one ability and keeps the token for the rest" do
    connection = GoogleConnection.store!(grant(scope: "openid #{CALENDAR} #{GMAIL}"), email: "a@example.com", user: alex, abilities: ALL)
    connection.drop!(:calendar)

    assert_equal [ :gmail ], connection.reload.abilities
    assert_equal TOKEN, connection.refresh_token
  end

  test "[unit] for(ability) is the newest readable connection granting it" do
    GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL, now: NOW)
    drive = GoogleConnection.store!(grant(scope: DRIVE), email: "b@example.com", user: alex, abilities: ALL, now: NOW + 1.minute)

    assert_equal "a@example.com", GoogleConnection.for(:calendar).email
    assert_equal drive, GoogleConnection.for(:drive)
    assert_nil GoogleConnection.for(:gmail)
  end

  test "[unit] ability reads a param and refuses anything else" do
    assert_equal :gmail, GoogleConnection.ability("gmail")
    assert_nil GoogleConnection.ability("contacts")
    assert_nil GoogleConnection.ability(nil)
  end

  test "[unit] the calendar row stored before the rename is still readable and still grants the calendar" do
    migration = RenameGoogleCalendarConnectionsToGoogleConnections.new
    migration.verbose = false
    migration.migrate(:down)
    legacy = Class.new(ApplicationRecord) do
      self.table_name = "google_calendar_connections"
      encrypts :refresh_token
      def self.name = "GoogleCalendarConnection"
    end
    legacy.create!(email: "alex@mcritchie.studio", refresh_token: TOKEN, scope: SCOPE, connected_at: NOW, connected_by: "alex", user_id: alex.id)
    assert_not_includes legacy.connection.select_value("SELECT refresh_token FROM google_calendar_connections"), TOKEN

    migration.migrate(:up)
    GoogleConnection.reset_column_information
    row = GoogleConnection.find_by!(email: "alex@mcritchie.studio")

    assert row.readable?
    assert_equal TOKEN, row.refresh_token
    assert_equal [ :calendar ], row.abilities
    assert_equal row, GoogleConnection.for(:calendar)
  end

  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, and a new sign-in replaces it" do
    old = GoogleConnection.store!(grant, email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW)
    assert old.readable? # the control

    with_other_encryption_key do
      assert_not GoogleConnection.find(old.id).readable?
      assert_no_difference -> { GoogleConnection.count } do
        GoogleConnection.store!(grant(refresh_token: "1//after-key-change"), email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW + 1.day)
      end
      row = GoogleConnection.current
      assert_not_equal old.id, row.id
      assert_equal "1//after-key-change", row.refresh_token
    end
  end
  # --- Ownership and the household (/tasks/every-user-connects-google) ---------

  test "[unit] a stored connection belongs to the user who signed it in" do
    viewer.update_column(:slug, "viewer-user-viewer@example.com")
    row = GoogleConnection.store!(grant, email: "viewer@gmail.test", user: viewer, abilities: ALL, now: NOW)

    assert_equal viewer, row.reload.user
    assert_equal viewer.slug, row.connected_by
    assert_includes viewer.google_connections, row
  end

  test "[unit] household holds only admin-owned connections" do
    household = GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL, now: NOW)
    own = GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW)

    assert_equal [ household ], GoogleConnection.household.to_a
    assert_includes GoogleConnection.all, own # the control: the viewer's row exists
  end

  test "[unit] for(ability) never answers a viewer's connection, even a newer one" do
    admins = GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL, now: NOW)
    viewers = GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW + 1.hour)
    assert viewers.can?(:calendar) # the control: the newer viewer row grants the ability

    assert_equal admins, GoogleConnection.for(:calendar)
    assert_equal admins, GoogleConnection.current
  end

  test "[unit] for(ability) is nil when only a viewer's connection grants it" do
    GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW)

    assert_nil GoogleConnection.for(:calendar)
    assert_nil GoogleConnection.current
  end

  test "[unit] a demoted admin's connection leaves the household" do
    row = GoogleConnection.store!(grant, email: "a@example.com", user: alex, abilities: ALL, now: NOW)
    assert_equal row, GoogleConnection.for(:calendar) # the control

    alex.update_column(:role, "viewer")
    assert_nil GoogleConnection.for(:calendar)
  end

  test "[unit] another user signing in an account already connected is refused and nothing changes" do
    row = GoogleConnection.store!(grant, email: "shared@example.com", user: alex, abilities: ALL, now: NOW)

    assert_raises(GoogleConnection::TakenByAnotherUser) do
      GoogleConnection.store!(grant(refresh_token: "1//takeover"), email: "Shared@Example.com", user: viewer, abilities: ALL, now: NOW + 1.hour)
    end
    row.reload
    assert_equal alex, row.user
    assert_equal TOKEN, row.refresh_token
    assert_equal NOW, row.connected_at
  end

  test "[unit] the same user signing in again keeps their row (incremental consent)" do
    GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW)
    both = GoogleConnection.store!(grant(scope: "openid #{DRIVE}"), email: "v@example.com", user: viewer, abilities: [ :drive ], now: NOW + 1.hour)

    assert_equal 1, GoogleConnection.count
    assert_equal %i[calendar drive], both.reload.abilities
  end

  test "[unit] an unreadable row another user owns is still refused, not replaced" do
    old = GoogleConnection.store!(grant, email: "shared@example.com", user: alex, abilities: ALL, now: NOW)
    with_other_encryption_key do
      assert_raises(GoogleConnection::TakenByAnotherUser) do
        GoogleConnection.store!(grant, email: "shared@example.com", user: viewer, abilities: ALL, now: NOW + 1.day)
      end
      assert_equal alex.id, GoogleConnection.find(old.id).user_id
    end
  end

  # --- /tasks/google-connect-hardening-polish ---

  # Runs the block as the loser of a race: `competitor`, the other sign-in,
  # has committed its row for the same account, but this sign-in's FIRST
  # lookup ran before that commit (it found no row) and its uniqueness
  # validation passed too, as two simultaneous callbacks do, so its insert
  # meets the unique index. (The competitor commits before the block because a
  # row inserted inside this sign-in's own savepoint would roll back with it.)
  # Later lookups are real.
  def racing(competitor)
    competitor.call
    calls = 0
    looked_up = lambda do |email|
      calls += 1
      next GoogleConnection.lock.find_or_initialize_by(email:) unless calls == 1

      GoogleConnection.new(email:).tap { |row| row.define_singleton_method(:valid?) { |*| true } }
    end
    GoogleConnection.stub(:row_for_update, looked_up) { yield }
    assert_equal 2, calls, "the race was run: one stale lookup, then one real one after the insert failed"
  end

  test "[unit] two simultaneous sign-ins of one new account by the same user resolve to one row" do
    racing(-> { GoogleConnection.store!(grant, email: "race@example.com", user: viewer, abilities: [ :calendar ], now: NOW) }) do
      GoogleConnection.store!(grant(scope: "openid #{DRIVE}"), email: "race@example.com", user: viewer, abilities: [ :drive ], now: NOW + 1.second)
    end

    row = GoogleConnection.sole
    assert_equal viewer, row.user
    assert_equal %i[calendar drive], row.abilities, "the second sign-in merged into the row the first inserted"
  end

  test "[unit] a sign-in racing another user's for the same new account is refused, never a second row" do
    racing(-> { GoogleConnection.store!(grant, email: "race@example.com", user: alex, abilities: ALL, now: NOW) }) do
      assert_raises(GoogleConnection::TakenByAnotherUser) do
        GoogleConnection.store!(grant(refresh_token: "1//loser"), email: "race@example.com", user: viewer, abilities: ALL, now: NOW)
      end
    end

    row = GoogleConnection.sole
    assert_equal alex, row.user
    assert_equal TOKEN, row.refresh_token
  end

  test "[unit] agents_read? is exactly membership of the household agents read" do
    household = GoogleConnection.store!(grant, email: "home@example.com", user: alex, abilities: ALL, now: NOW)
    own = GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW)

    assert household.agents_read?
    refute own.agents_read?
    [ household, own ].each do |row|
      assert_equal GoogleConnection.household.exists?(row.id), row.agents_read?, row.email
    end
  end

  test "[unit] who_reads says agents read a household connection and only the owner sees their own" do
    household = GoogleConnection.store!(grant, email: "home@example.com", user: alex, abilities: ALL, now: NOW)
    own = GoogleConnection.store!(grant, email: "v@example.com", user: viewer, abilities: ALL, now: NOW)

    assert_equal "Your agents can read this", household.who_reads
    assert_equal "Only you can see this", own.who_reads, "a viewer who owns no app: no agent reads it"
  end

  test "[unit] an app owner's own connection says their app's agent reads it in their chat" do
    # /tasks/agent-reads-owner-google: the client CTO reads its app owner's own
    # rows on that owner's own thread (OwnerContext.for_user), and no one else's.
    owner = User.create!(email: "app-owner@example.com", name: "App Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    row = GoogleConnection.store!(grant, email: "owner@example.com", user: owner, abilities: ALL, now: NOW)

    assert_equal :app_agent, row.reader
    assert_equal "Your app's agent can read this when you chat with it", row.who_reads
    assert_equal [ row ], GoogleConnection.owned_by(owner).to_a, "the rows the owner's app agent reads"
    assert_nil GoogleConnection.for(:calendar), "the household's agents still do not"
  end

  test "[unit] the ownership migration backfills each row from connected_by, falling back to the operator" do
    alex.update_column(:slug, "alex-mcritchie-alex@mcritchie.studio")
    viewer.update_column(:slug, "viewer-user-viewer@example.com")
    migration = AddUserToGoogleConnections.new
    migration.verbose = false
    migration.migrate(:down)
    insert = lambda do |email, by|
      GoogleConnection.connection.execute(<<~SQL.squish)
        INSERT INTO google_connections (email, refresh_token, connected_by, connected_at, created_at, updated_at)
        VALUES (#{GoogleConnection.connection.quote(email)}, 'ciphertext', #{GoogleConnection.connection.quote(by)}, now(), now(), now())
      SQL
    end
    insert.("a@example.com", alex.slug)
    insert.("v@example.com", viewer.slug)
    insert.("gone@example.com", "a-user-since-deleted")

    migration.migrate(:up)
    GoogleConnection.reset_column_information
    owners = GoogleConnection.pluck(:email, :user_id).to_h

    assert_equal({ "a@example.com" => alex.id, "v@example.com" => viewer.id, "gone@example.com" => alex.id }, owners)
    assert_not GoogleConnection.columns_hash["user_id"].null, "user_id is required once backfilled"
  end

  test "[unit] owned_by is one user's own rows, never another user's, admin or not" do
    viewer = users(:viewer)
    mine = GoogleConnection.store!(grant, email: "viewer@example.com", user: viewer, abilities: ALL, now: NOW)
    GoogleConnection.store!(grant, email: "alex@mcritchie.studio", user: alex, abilities: ALL, now: NOW)

    assert_equal [ mine ], GoogleConnection.owned_by(viewer).to_a
    assert_equal [ "alex@mcritchie.studio" ], GoogleConnection.owned_by(alex).pluck(:email)
    assert_not_includes GoogleConnection.household.to_a, mine, "a viewer's row is still never the household's"
  end
end
