require "test_helper"
require "csv"

# [unit] script/contacts/cyvasse_new_stack_players.rb (task
# first-game-feedback-survey): the SQL that runs on the cyvasse app, checked
# against cyvasse-shaped users and matches tables in a throwaway schema (rolled
# back with the test). Loading the file defines the module and runs nothing.
class CyvasseNewStackPlayersScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/contacts/cyvasse_new_stack_players.rb").to_s
  COMPUTERS = (2..10)
  NEW = Time.utc(2026, 9, 29, 15)

  setup do
    load SCRIPT
    @db = ActiveRecord::Base.connection
    @db.execute(<<~SQL)
      CREATE SCHEMA cyvasse_fixture;
      SET LOCAL search_path TO cyvasse_fixture;
      CREATE TABLE users (id bigserial PRIMARY KEY, email varchar, username varchar, guest boolean NOT NULL DEFAULT false,
        legacy_id integer, merged_into_id bigint);
      CREATE TABLE matches (id bigserial PRIMARY KEY, home_user_id bigint NOT NULL, away_user_id bigint NOT NULL,
        last_move varchar, legacy_id integer, created_at timestamp NOT NULL);
    SQL
    @computer = user("computer@example.com", legacy_id: 3)
  end

  def user(email, **attrs)
    cols = { email: }.merge(attrs)
    @db.select_value("INSERT INTO users (#{cols.keys.join(", ")}) VALUES (#{cols.values.map { |v| @db.quote(v) }.join(", ")}) RETURNING id")
  end

  def match(home, away, at: NEW, last_move: "a1-b2", legacy_id: nil)
    @db.execute("INSERT INTO matches (home_user_id, away_user_id, last_move, legacy_id, created_at) VALUES " \
                "(#{[ home, away, last_move, legacy_id, at ].map { |v| @db.quote(v) }.join(", ")})")
  end

  def players
    lines = CyvasseNewStackPlayers.lines(@db, computers: COMPUTERS)
    assert_equal "email,first_new_game_on,new_games", lines.first.chomp
    lines.drop(1).map { |line| CSV.parse_line(line) }.index_by(&:first)
  end

  test "a player with a played match since the relaunch is listed with the first date and the count" do
    vey = user("vey@example.com")
    match(vey, @computer, at: Time.utc(2026, 10, 2, 1))
    match(@computer, vey, at: NEW)
    assert_equal [ "vey@example.com", "2026-09-29", "2" ], players["vey@example.com"]
  end

  test "both seats of a person-vs-person match are listed" do
    a = user("a@example.com")
    b = user("b@example.com")
    match(a, b)
    assert_equal %w[a@example.com b@example.com], players.keys.sort
  end

  test "guests, computers, merged accounts and blank emails are left out" do
    guest = user("guest@example.com", guest: true)
    merged = user("merged@example.com", merged_into_id: 1)
    blank = user("")
    [ guest, merged, blank ].each { |id| match(id, @computer) }
    assert_empty players
  end

  test "a match before the relaunch, a legacy import, or one without a move is not a new-stack game" do
    old = user("old@example.com")
    match(old, @computer, at: Time.utc(2026, 9, 27, 23, 59))
    legacy = user("legacy@example.com")
    match(legacy, @computer, legacy_id: 77)
    idle = user("idle@example.com")
    match(idle, @computer, last_move: nil)
    match(idle, @computer, last_move: "")
    assert_empty players
  end
end
