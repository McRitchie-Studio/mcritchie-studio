require "test_helper"

# [unit] The "Your games" tiers (task tiered-your-games-copy): the subject a
# reader gets from their games and wins, its fallbacks when a stat is missing,
# and the pluralized counts it and the body show. Production had 2,037 readers
# with one game whose subject read "your 1 Cyvasse games"; no tier may.
class Broadcasts::CyvasseYourGamesTest < ActiveSupport::TestCase
  STORED = "%{username}, your %{games} Cyvasse games are still here".freeze

  setup do
    @broadcast = Broadcast.new(template_key: "cyvasse_your_games", subject: STORED)
  end

  def subject_for(**fields) = @broadcast.subject_for({ "username" => "Ann" }.merge(fields.transform_keys(&:to_s)))
  def tier(**fields) = Broadcasts::CyvasseYourGames.tier(fields.transform_keys(&:to_s))

  test "tiers split at 5 and 20 games" do
    assert_equal :newcomer, tier(games: 1)
    assert_equal :newcomer, tier(games: 4)
    assert_equal :regular,  tier(games: 5)
    assert_equal :regular,  tier(games: 19)
    assert_equal :veteran,  tier(games: 20)
    assert_equal :veteran,  tier(games: 1300)
  end

  test "a missing, blank or non-numeric games count is the newcomer tier, never a raise" do
    assert_equal :newcomer, tier
    assert_equal :newcomer, tier(games: "")
    assert_equal :newcomer, tier(games: "lots")
    assert_equal :newcomer, Broadcasts::CyvasseYourGames.tier(nil)
    assert_equal :regular, tier(games: "7"), "a count stored as a string still counts"
  end

  test "20+ games: the broadcast's own subject" do
    assert_equal "Ann, your 20 Cyvasse games are still here", subject_for(games: 20, wins: 9)
    assert_equal "Ann, your 518 Cyvasse games are still here", subject_for(games: 518)
  end

  test "5-19 games with wins: games and wins, each pluralized" do
    assert_equal "Ann, your 7 games and 3 wins are still here", subject_for(games: 7, wins: 3)
    assert_equal "Ann, your 5 games and 1 win are still here", subject_for(games: 5, wins: 1)
    assert_equal "Ann, your 19 games and 19 wins are still here", subject_for(games: 19, wins: "19")
  end

  test "5-19 games with no wins, or wins missing: the games line" do
    assert_equal "Ann, your 7 Cyvasse games are still here", subject_for(games: 7, wins: 0)
    assert_equal "Ann, your 7 Cyvasse games are still here", subject_for(games: 7)
    assert_equal "Ann, your 7 Cyvasse games are still here", subject_for(games: 7, wins: "")
  end

  test "1-4 games: the account line, with no count to get wrong" do
    assert_equal "Ann, your Cyvasse account is still here", subject_for(games: 1)
    assert_equal "Ann, your Cyvasse account is still here", subject_for(games: 4, wins: 2)
  end

  test "the stored subject is still what the veteran tier sends, so an edit reaches it" do
    @broadcast.subject = "%{username}: %{games} games, still yours"
    assert_equal "Ann: 40 games, still yours", subject_for(games: 40)
    assert_equal "Ann, your Cyvasse account is still here", subject_for(games: 2)
  end

  test "a username's line breaks collapse and its %{} is not interpolated again" do
    assert_equal "A nn, your Cyvasse account is still here", @broadcast.subject_for("username" => "A\r\nnn", "games" => 1)
    assert_equal "%{games}, your 6 games and 2 wins are still here",
                 @broadcast.subject_for("username" => "%{games}", "games" => 6, "wins" => 2)
  end

  test "a missing username is left as written, never blanked" do
    assert_equal "%{username}, your Cyvasse account is still here", @broadcast.subject_for("games" => 1)
  end

  test "another template keeps its stored subject" do
    other = Broadcast.new(template_key: "cyvasse_is_back", subject: "%{username}, Cyvasse is back")
    assert_equal "Ann, Cyvasse is back", other.subject_for("username" => "Ann", "games" => 1)
  end

  test "counted pluralizes by the number" do
    assert_equal "1 game", Broadcasts::MergeFields.counted(1, "game")
    assert_equal "2 games", Broadcasts::MergeFields.counted(2, "game")
    assert_equal "0 wins", Broadcasts::MergeFields.counted(0, "win")
    assert_equal "1 win", Broadcasts::MergeFields.counted("1", "win")
    assert_equal "1 loss", Broadcasts::MergeFields.counted(1, "loss")
    assert_equal "3 losses", Broadcasts::MergeFields.counted(3, "loss")
  end

  test "with_counts adds a phrase per present count and leaves the raw values" do
    fields = Broadcasts::MergeFields.with_counts("games" => 1, "wins" => 0, "username" => "Ann")
    assert_equal 1, fields["games"]
    assert_equal "1 game", fields["games_count"]
    assert_equal "0 wins", fields["wins_count"]
    assert_not fields.key?("losses_count"), "no phrase for a count the reader lacks"
  end

  test "joined_year reads the year of joined_on, or nil" do
    assert_equal "2014", Broadcasts::CyvasseYourGames.joined_year("joined_on" => "2014-03-02")
    assert_nil Broadcasts::CyvasseYourGames.joined_year({})
  end

  test "the night link is a tracked template link" do
    assert_equal "https://cyvasse.xyz/night", @broadcast.link_for("night")
    assert_includes @broadcast.link_keys, "night"
  end
end
