require "test_helper"
require_relative "../../support/daily_app_report_fixtures"

# [unit] DailyAppReport::Message — the one Discord message, fitted to Discord's
# limits by construction (ReportDestinations refuses an over-limit report).
class DailyAppReport::MessageTest < ActiveSupport::TestCase
  ENDING = Time.find_zone("America/Denver").local(2026, 10, 15, 7)

  def health(slug, state: :ok, reason: nil, signups: 0, errors: 0, groups: [], name: nil, failure: nil)
    DailyAppReport::AppHealth.new(
      slug: slug, name: name || slug.titleize, state: state, reason: reason, engine_version: "0.108.0",
      sections: state == :ok ? [ { key: "signups", title: "Signups", count: signups, failure: nil },
                                 { key: "errors", title: "Errors", count: errors, failure: failure } ] : nil,
      error_kinds: groups.size, error_groups: groups
    )
  end

  # Every app with 15 long error groups: long classes, long messages, emoji
  # (2 UTF-16 units each), newlines and backticks.
  def worst_groups
    15.times.map do |i|
      { error_class: "Very::Long::Namespace::#{'Deep' * 20}Error#{i}",
        message: "🔥 `boom` #{'x' * 280}\nline two 🧨 #{i}", count: 10_000 + i }
    end
  end

  def build(results) = DailyAppReport::Message.new(ending: ENDING, results: results)

  test "[unit] the worst case fits every Discord limit and ReportDestinations accepts it" do
    long = "App With An Extremely Long Display Name 🐊 " * 10
    results = 25.times.map { |i| health("app-#{i}", name: "#{long}#{i}", errors: 99_999, signups: 9_999, groups: worst_groups) }
    built = build(results).to_h

    assert_nothing_raised { ReportDestinations.check_limits!(built[:content], built[:embeds]) }
    assert_equal 10, built[:embeds].size
    assert_operator ReleaseNotes::DiscordClient.discord_length(built[:content]), :<=, 2000
    total = built[:embeds].sum { |e| ReleaseNotes::DiscordClient.embed_length(e) }
    assert_operator total, :<=, 6000
    # The fifteen apps without an embed are folded into the content, not dropped silently.
    assert_includes built[:content], "Also:"
    assert_match(/…and \d+ more|App With/, built[:content].lines.last)
  end

  test "[unit] the worst case at exactly ten apps still shows each app's top error and counts the rest" do
    results = 10.times.map { |i| health("app-#{i}", errors: 500, groups: worst_groups) }
    built = build(results).to_h

    assert_nothing_raised { ReportDestinations.check_limits!(built[:content], built[:embeds]) }
    built[:embeds].each do |embed|
      assert_includes embed[:description], "Signups 0 · Errors 500"
      assert_includes embed[:description], "`Very::Long::Namespace"
      assert_match(/\+\d+ more\z/, embed[:description])
      refute_includes embed[:description], "\nline two" # one line per group
      assert_equal DailyAppReport::Message::AMBER, embed[:color]
    end
  end

  test "[unit] a quiet day is one green embed per app and a quiet headline" do
    built = build([ health("mcritchie-studio", name: "McRitchie Studio"), health("turf-monster", name: "Turf Monster") ]).to_h

    assert_includes built[:content], "**Daily app report · Thu, Oct 15, 2026**"
    assert_includes built[:content], "2 apps: 2 quiet"
    assert_includes built[:content], "Window: Oct 14, 7:00 AM to Oct 15, 7:00 AM MDT"
    assert_equal [ DailyAppReport::Message::GREEN ] * 2, built[:embeds].map { |e| e[:color] }
    assert_equal "Signups 0 · Errors 0", built[:embeds].first[:description]
    assert_equal "studio-engine 0.108.0", built[:embeds].first.dig(:footer, :text)
  end

  test "[unit] not-wired apps are listed in the content, unreachable ones get a red embed first" do
    results = [ health("mcritchie-studio", name: "McRitchie Studio", signups: 2),
                health("cyvasse", name: "Cyvasse", state: :not_wired),
                health("turf-monster", name: "Turf Monster", state: :unreachable, reason: "timeout"),
                health("rantly", name: "Rantly", errors: 3, groups: [ { error_class: "Foo", message: "bar", count: 3 } ]) ]
    built = build(results).to_h

    assert_includes built[:content], "4 apps: 1 with activity, 1 with errors, 1 unreachable, 1 not wired"
    assert_includes built[:content], "Not wired (no token): Cyvasse"
    assert_equal [ "Turf Monster", "Rantly", "McRitchie Studio" ], built[:embeds].map { |e| e[:title] }
    assert_equal "Unreachable (timeout)", built[:embeds].first[:description]
    assert_equal DailyAppReport::Message::RED, built[:embeds].first[:color]
    assert_includes built[:embeds].second[:description], "`Foo` ×3: bar"
  end

  test "[unit] email addresses in error messages never reach Discord" do
    groups = [ { error_class: "ActiveRecord::RecordInvalid", message: "Email jane.doe+x@example.co.uk has been taken", count: 1 } ]
    built = build([ health("turf-monster", errors: 1, groups: groups) ]).to_h

    refute_includes built[:embeds].first[:description], "jane.doe"
    assert_includes built[:embeds].first[:description], "Email [email] has been taken"
  end

  test "[unit] a section the app could not read turns the embed amber and says so" do
    built = build([ health("turf-monster", failure: "PG::ConnectionBad") ]).to_h

    assert_equal "Signups 0 · Errors unavailable", built[:embeds].first[:description]
    assert_equal DailyAppReport::Message::AMBER, built[:embeds].first[:color]
  end

  test "[unit] clip measures UTF-16 and ends in an ellipsis" do
    clipped = DailyAppReport::Message.clip("🔥" * 10, 7)
    assert_equal "🔥🔥🔥…", clipped
    assert_operator ReleaseNotes::DiscordClient.discord_length(clipped), :<=, 7
    assert_equal "short", DailyAppReport::Message.clip("short", 7)
  end
end
