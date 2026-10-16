require "test_helper"
require_relative "../../support/daily_app_report_fixtures"

# [unit] CtoReport::Message: each CTO's template voice over computed facts, for
# every state an app can be in, inside Discord's limits, counts only.
class CtoReport::MessageTest < ActiveSupport::TestCase
  include DailyAppReportFixtures

  ENDING = Time.find_zone("America/Denver").local(2026, 10, 15, 7)

  def entry(slug, name, soul, domain: slug.tr("-", "_")) = CtoReport::Entry.new(domain: domain, app: app_entry(slug, name: name), soul: soul)
  def hub = entry("mcritchie-studio", "McRitchie Studio", "avi")
  def turf = entry("turf-monster", "Turf Monster", "turf_monster")
  def cyvasse = entry("cyvasse", "Cyvasse", "tyrion")

  def health(entry, body = nil, state: :ok, reason: nil)
    return DailyAppReport::AppHealth.new(slug: entry.app.slug, name: entry.app.name, state: state, reason: reason) unless state == :ok

    DailyAppReport.from_json(entry.app, body)
  end

  def build_message(entry, health, board: nil) = CtoReport::Message.new(entry: entry, ending: ENDING, health: health, board: board)

  def board(stages: { "designed" => 2, "building" => 3, "submitted" => 1, "reviewed" => 1, "assembled" => 4 }, blocked: 0,
            shipped: 5, release: { stage: "qa_deployed", tasks: 4 })
    CtoReport::BoardFacts.new(stages: stages, blocked: blocked, shipped: shipped, release: release)
  end

  test "[unit] Avi: a quiet hub day, with the board, the shipped count and the release" do
    text = build_message(hub, health(hub, health_body), board: board).content

    assert_equal <<~TEXT.chomp, text
      **McRitchie Studio · CTO report · Thu, Oct 15, 2026**
      Morning. Here is McRitchie Studio for the day to Oct 15, 7:00 AM MDT. A quiet day: no errors and nothing new.
      On the board: 5 in build, 1 waiting on review, 5 on the way to production, 5 shipped in the window. Release in flight: qa deployed, 4 tasks.
      — Avi
    TEXT
  end

  test "[unit] the hub board: blocked tasks are counted, and no release in flight says so" do
    text = build_message(hub, health(hub, health_body), board: board(blocked: 2, release: nil, shipped: 0)).content

    assert_includes text, "On the board: 5 (2 blocked) in build"
    assert_includes text, "0 shipped in the window. No release in flight."
  end

  test "[unit] the usage line sits above the signature; no usage, no line" do
    usage = AgentUsage::Totals.new(messages: 3, input_tokens: 30, cache_read_tokens: 12_000, cache_creation_tokens: 900,
                                   output_tokens: 420, thinking_tokens: 100, cost_usd: 0.1234, duration_ms: 9_000, timed: 3)
    text = CtoReport::Message.new(entry: turf, ending: ENDING, health: health(turf, health_body), usage: usage).content
    lines = text.lines.map(&:chomp)

    assert_equal "Agent usage, the day: 3 answers, 13,350 tokens (in 30 · cache read 12,000 · cache write 900 · out 420), " \
                 "$0.12, avg 3.0s.", lines[-2]
    assert_equal "— Turf", lines[-1]
    quiet = CtoReport::Message.new(entry: turf, ending: ENDING, health: health(turf, health_body), usage: AgentUsage::Totals.zero).content
    assert_includes quiet, "Agent usage, the day: no answers."
    refute_includes build_message(turf, health(turf, health_body)).content, "Agent usage"
  end

  test "[unit] only the hub carries a board line" do
    refute_includes build_message(turf, health(turf, health_body(signups: 2))).content, "On the board"
  end

  test "[unit] Turf: activity is counted from the sections, singular and plural" do
    text = build_message(turf, health(turf, health_body(signups: 3, contacts: 1))).content

    assert_includes text, "Morning from the Turf Monster booth. Box score for the day to Oct 15, 7:00 AM MDT."
    assert_includes text, "3 signups and 1 contact message, and zero errors. Clean game."
    assert text.end_with?("— Turf")
  end

  test "[unit] Turf: errors are counted with their kinds; the embed carries the groups" do
    msg = build_message(turf, health(turf, health_body(errors: 12, groups: [ [ "Foo", "bar", 10 ], [ "Baz", "qux", 2 ] ])))

    assert_includes msg.content, "12 errors in 2 kinds. Flag on the play; worth a review."
    embed = msg.embeds.sole
    assert_equal "Turf Monster", embed[:title]
    assert_includes embed[:description], "Signups 0 · Errors 12"
    assert_includes embed[:description], "`Foo` ×10: bar"
    assert_equal DailyAppReport::Message::AMBER, embed[:color]
  end

  test "[unit] a section the app could not read is a problem even with no errors" do
    body = health_body
    body["sections"] << { "key" => "contacts", "title" => "Contact messages", "count" => 0, "failure" => "PG::Error" }
    text = build_message(cyvasse, health(cyvasse, body)).content

    assert_includes text, "Contact messages could not be read. Debts like these compound if nobody looks."
  end

  test "[unit] Tyrion: quiet and activity in his own register" do
    assert_includes build_message(cyvasse, health(cyvasse, health_body)).content,
                    "Cyvasse's ledger for the day to Oct 15, 7:00 AM MDT. A quiet day: no errors, no newcomers. Peace is underrated."
    assert_includes build_message(cyvasse, health(cyvasse, health_body(signups: 1))).content,
                    "1 signup, and not a single error. I would drink to that, modestly."
    assert build_message(cyvasse, health(cyvasse, health_body)).content.end_with?("— Tyrion")
  end

  test "[unit] unreachable: each voice says why and gives no numbers and no embed" do
    { hub => "I could not read the health report (timeout), so I have no numbers for you today.",
      turf => "No feed from the app today (timeout), so no box score.",
      cyvasse => "The ravens brought nothing (timeout). No numbers today." }.each do |e, line|
      msg = build_message(e, health(e, state: :unreachable, reason: "timeout"))
      assert_includes msg.content, line
      assert_empty msg.embeds
    end
  end

  test "[unit] counts only: an email in a reason or an error message never reaches the post" do
    msg = build_message(turf, health(turf, state: :unreachable, reason: "refused for ops@example.com"))
    refute_includes msg.content, "ops@example.com"
    assert_includes msg.content, "[email]"

    msg = build_message(turf, health(turf, health_body(errors: 1, groups: [ [ "Foo", "no user jane@example.com", 1 ] ])))
    refute_includes msg.to_h.to_s, "jane@example.com"
  end

  test "[unit] Discord limits: a huge reason or error list still fits what ReportDestinations accepts" do
    groups = (1..40).map { |i| [ "Error#{i}#{'X' * 200}", "m" * 500, i ] }
    [ build_message(turf, health(turf, health_body(errors: 40, groups: groups))),
      build_message(turf, health(turf, state: :unreachable, reason: "🔥" * 3_000)),
      build_message(hub, health(hub, health_body(errors: 40, groups: groups)), board: board) ].each do |msg|
      h = msg.to_h
      assert_operator ReleaseNotes::DiscordClient.discord_length(h[:content]), :<=, ReportDestinations::CONTENT_LIMIT
      assert_nothing_raised { ReportDestinations.check_limits!(h[:content], h[:embeds]) }
    end
  end

  test "[unit] every soul in config/cto_reports.yml has a voice with every line" do
    CtoReport.config.each_value do |row|
      voice = CtoReport::Voice.for(row["soul"])
      assert_equal %i[signature open quiet activity errors unreachable board].sort, voice.keys.sort, row["soul"]
    end
    assert_raises(KeyError) { CtoReport::Voice.for("nobody") }
  end

  test "[unit] every voice speaks every state: healthy, activity, errors, unreachable, each with its own line and signature" do
    [ hub, turf, cyvasse ].each do |e|
      voice = CtoReport::Voice.for(e.soul)
      states = { quiet: health(e, health_body), activity: health(e, health_body(signups: 1)),
                 errors: health(e, health_body(errors: 2, groups: [ [ "Foo", "x", 2 ] ])),
                 unreachable: health(e, state: :unreachable, reason: "timeout") }
      texts = states.transform_values { |h| build_message(e, h).content }
      assert_equal 4, texts.values.uniq.size, e.soul
      texts.each_value { |t| assert t.end_with?("— #{voice[:signature]}"), "#{e.soul}: #{t}" }
      assert_includes texts[:errors], "2 errors in 1 kind", e.soul
    end
  end
end
