# frozen_string_literal: true

require "test_helper"

# [unit] Release::DevnetGauntlet: a release carrying turf-monster or turf-vault work
# ships only after a green contest-rehearsal on QA is recorded on it. The ship reads
# the record in its production snapshot (SNAPSHOT_RUBY), so that fragment is run
# here against real rows, not only matched as text.
class Release::DevnetGauntletTest < ActiveSupport::TestCase
  G = Release::DevnetGauntlet
  SHAS = { "turf-monster" => "aaaa1111bbbb", "turf-vault" => "cccc2222dddd" }.freeze
  RECORD = { "occurred_at" => "2026-10-11T15:00:00Z", "actor" => "turf_monster", "status" => "completed",
             "metadata" => { "shas" => SHAS } }.freeze

  test "only a Turf repo owes the gauntlet" do
    assert G.required?(%w[mcritchie-studio turf-monster])
    assert G.required?(%w[turf-vault])
    refute G.required?(%w[mcritchie-studio studio-engine rolio])
    assert_equal [:not_required, nil], G.verdict(repos: %w[mcritchie-studio], snapshot: {})
  end

  test "a Turf release with a recorded gauntlet ships and says so" do
    verdict, message = G.verdict(repos: %w[turf-monster], snapshot: { G::STEP => RECORD }, shas: SHAS)

    assert_equal :recorded, verdict
    assert_equal "devnet gauntlet recorded 2026-10-11T15:00:00Z by turf_monster for turf-monster@aaaa111", message
  end

  test "a Turf release without one is refused, naming the rehearsal, the record and the override" do
    verdict, message = G.verdict(repos: %w[turf-monster turf-vault], snapshot: { G::STEP => nil })

    assert_equal :refused, verdict
    assert_includes message, "carries turf-monster and turf-vault"
    assert_includes message, "turf_monster/sops/contest-rehearsal.md"
    assert_includes message, "/api/v1/releases/current/events/devnet_gauntlet/complete"
    assert_includes message, "--skip-devnet-gauntlet"
  end

  test "the override needs words, and only stands in for a missing record" do
    assert_equal :refused, G.verdict(repos: %w[turf-vault], snapshot: { G::STEP => nil }, waiver: "  ").first
    verdict, message = G.verdict(repos: %w[turf-vault], snapshot: { G::STEP => nil }, waiver: "devnet is down, ship it")
    assert_equal :waived, verdict
    assert_includes message, "\"devnet is down, ship it\""
    assert_equal :recorded, G.verdict(repos: %w[turf-vault], snapshot: { G::STEP => RECORD }, shas: SHAS, waiver: "x").first
  end

  test "a snapshot that never asked is unknown, not a pass and not a refusal" do
    assert_equal :unknown, G.verdict(repos: %w[turf-monster], snapshot: { "slug" => "rel" }).first
  end

  test "the snapshot fragment reads the newest completed gauntlet event off a real release" do
    release = Release.create!(slug: "rel-gauntlet", branch: "release", state: "assembled")
    read = ->(r) { JSON.parse(eval("{ #{G::SNAPSHOT_RUBY} }", binding).to_json) } # rubocop:disable Security/Eval

    assert_equal({ G::STEP => nil }, read.call(release), "none recorded")

    release.record_event!(step: G::STEP, status: "started", actor: "turf_monster")
    assert_nil read.call(release)[G::STEP], "a started gauntlet is not a green one"

    release.record_event!(step: G::STEP, status: "completed", actor: "turf_monster", source: "agent",
                          model: "claude-opus", tokens_in: 1, tokens_out: 1, cost: 0, occurred_at: 2.minutes.ago,
                          metadata: { "contest" => "qa-rehearsal-1", "shas" => SHAS })
    recorded = read.call(release)[G::STEP]
    assert_equal "turf_monster", recorded["actor"]
    assert_equal "completed", recorded["status"]
    assert_equal "qa-rehearsal-1", recorded.dig("metadata", "contest")
    assert_equal :recorded, G.verdict(repos: %w[turf-monster], snapshot: read.call(release), shas: SHAS).first

    release.record_event!(step: G::STEP, status: "failed", actor: "turf_monster", source: "conductor",
                          occurred_at: 1.minute.ago, metadata: { "failed_step" => "play" })
    assert_equal "failed", read.call(release).dig(G::STEP, "status"), "the newest terminal event is read, red or green"
    verdict, message = G.verdict(repos: %w[turf-monster], snapshot: read.call(release), shas: SHAS)
    assert_equal :refused, verdict, "a red gauntlet newer than a green one refuses"
    assert_includes message, "newest devnet gauntlet is RED"
  end

  test "a green record covers only the Turf SHAs it tested" do
    stale = SHAS.merge("turf-monster" => "eeee3333ffff")
    verdict, message = G.verdict(repos: %w[turf-monster], snapshot: { G::STEP => RECORD }, shas: stale)

    assert_equal :refused, verdict, "new Turf code on the release ships only after its own gauntlet"
    assert_includes message, "the newest green one tested turf-monster@aaaa111, this ship ships turf-monster@eeee333"
    assert G.covers?(RECORD, turf: %w[turf-monster turf-vault], shas: SHAS)
    refute G.covers?(RECORD.merge("metadata" => {}), turf: %w[turf-monster], shas: SHAS), "a record with no SHAs covers nothing"
    refute G.covers?(RECORD, turf: %w[turf-monster], shas: {}), "an unknown shipping SHA is not covered"
    refute G.covers?(RECORD.merge("status" => "failed"), turf: %w[turf-monster], shas: SHAS)
    assert_equal :waived, G.verdict(repos: %w[turf-monster], snapshot: { G::STEP => RECORD }, shas: stale,
                                    waiver: "his words").first
  end
end
