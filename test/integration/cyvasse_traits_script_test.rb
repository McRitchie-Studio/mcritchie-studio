require "test_helper"
require "csv"

# [unit] script/contacts/cyvasse_traits.rb (task contact-traits-from-cyvasse):
# the SQL that runs on the cyvasse app, checked here against cyvasse-shaped
# users and matches tables in a throwaway schema (rolled back with the test).
# Loading the file defines CyvasseTraits and runs nothing: the script only
# prints when `bin/rails runner` sets $0 to it.
class CyvasseTraitsScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/contacts/cyvasse_traits.rb").to_s
  COMPUTERS = (2..10)
  RESULTS = %w[king resigned forfeit draw].freeze
  AT = Time.utc(2025, 5, 5)

  setup do
    load SCRIPT
    @db = ActiveRecord::Base.connection
    @db.execute(<<~SQL)
      CREATE SCHEMA cyvasse_fixture;
      SET LOCAL search_path TO cyvasse_fixture;
      CREATE TABLE users (id bigserial PRIMARY KEY, email varchar, username varchar, guest boolean NOT NULL DEFAULT false,
        legacy_id integer, wins integer NOT NULL DEFAULT 0, losses integer NOT NULL DEFAULT 0, merged_into_id bigint,
        created_at timestamp NOT NULL DEFAULT '2020-01-01', updated_at timestamp NOT NULL DEFAULT '2020-01-01');
      CREATE TABLE matches (id bigserial PRIMARY KEY, home_user_id bigint NOT NULL, away_user_id bigint NOT NULL,
        match_status varchar, finish_reason varchar, turn integer DEFAULT 0, last_move varchar,
        time_of_last_move timestamp, legacy_id integer);
    SQL
    @opponent = user("opp@example.com", "opp")
  end

  def user(email, username, **attrs)
    cols = { email:, username: }.merge(attrs)
    @db.select_value("INSERT INTO users (#{cols.keys.join(", ")}) VALUES (#{cols.values.map { |v| @db.quote(v) }.join(", ")}) RETURNING id")
  end

  # A match between `id` and the opponent. last_move set = a move was made.
  def match(id, status:, reason: nil, turn: 0, last_move: nil, legacy_id: nil, at: AT)
    @db.execute("INSERT INTO matches (home_user_id, away_user_id, match_status, finish_reason, turn, last_move, " \
                "time_of_last_move, legacy_id) VALUES (#{[ @opponent, id, status, reason, turn, last_move, at, legacy_id ].map { |v| @db.quote(v) }.join(", ")})")
  end

  def traits
    CyvasseTraits.lines(@db, computers: COMPUTERS, results: RESULTS, synced_at: AT).drop(1)
                 .map { |line| CyvasseTraits::HEADER.zip(CSV.parse_line(line)).to_h }.index_by { |row| row["email"] }
  end

  def games(email) = traits.fetch(email).values_at("games", "finished_games").map(&:to_i)

  test "an unanswered challenge is 0 games" do
    id = user("pending@example.com", "pending")
    match(id, status: "pending")
    assert_equal [ 0, 0 ], games("pending@example.com")
  end

  test "accepted but never started, and expired before play, are 0 games" do
    id = user("expired@example.com", "expired")
    match(id, status: "new")
    match(id, status: "finished", reason: "expired", legacy_id: 1)
    match(id, status: "finished", reason: "expired", turn: 1)
    assert_equal [ 0, 0 ], games("expired@example.com")
  end

  test "an abandoned match with moves is 1 game and 0 finished; one without moves is nothing" do
    id = user("abandoned@example.com", "abandoned")
    match(id, status: "finished", reason: "abandoned", turn: 1, last_move: "12,13", legacy_id: 1)
    match(id, status: "finished", reason: "abandoned", turn: 0, legacy_id: 2)
    assert_equal [ 1, 0 ], games("abandoned@example.com")
  end

  test "a king ending is 1 finished game; a game in progress is a game, not finished" do
    id = user("king@example.com", "king")
    match(id, status: "finished", reason: "king", turn: 40, last_move: "1,2")
    match(id, status: "in progress", turn: 5, last_move: "3,4")
    match(id, status: "in progress", turn: 1)
    assert_equal [ 2, 1 ], games("king@example.com")
  end

  test "resigned, forfeit and draw are results; a forfeit before any move is in neither count" do
    id = user("results@example.com", "results")
    %w[resigned forfeit draw].each { |reason| match(id, status: "finished", reason:, turn: 9, last_move: "5,6") }
    match(id, status: "finished", reason: "forfeit", turn: 0, legacy_id: 3)
    assert_equal [ 3, 3 ], games("results@example.com")
  end

  test "last active ignores a challenge nobody played" do
    id = user("recent@example.com", "recent")
    match(id, status: "finished", reason: "king", turn: 9, last_move: "1,2", at: Time.utc(2024, 1, 1))
    match(id, status: "pending", at: Time.utc(2026, 9, 1))
    assert_equal "2024-01-01", traits.fetch("recent@example.com")["last_active_on"]
  end

  test "guests, computers and merged accounts are left out; rank follows the all-time board" do
    user("guest@example.com", "Guest_1", guest: true)
    user("bot@example.com", "botty", legacy_id: 3, wins: 99)
    user("merged@example.com", "merged", merged_into_id: 1)
    user("a@example.com", "a", wins: 20, losses: 7)
    user("b@example.com", "b", wins: 20, losses: 3)
    rows = traits
    assert_equal %w[a@example.com b@example.com opp@example.com], rows.keys.sort
    assert_equal [ "2", "1", nil ], rows.values_at("a@example.com", "b@example.com", "opp@example.com").map { |r| r["all_time_rank"] }
  end

  test "loading the script prints nothing" do
    out, err = capture_io { load SCRIPT }
    assert_equal "", out
    assert_no_match(/cyvasse_traits:|CYVT/, err)
  end
end
