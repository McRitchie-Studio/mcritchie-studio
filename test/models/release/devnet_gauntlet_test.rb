# frozen_string_literal: true

require "test_helper"

# [unit] Release::DevnetGauntlet: a release carrying turf-monster or turf-vault work
# ships only after a green contest-rehearsal on QA is recorded on it. The ship reads
# the record in its production snapshot (SNAPSHOT_RUBY), so that fragment is run
# here against real rows, not only matched as text.
class Release::DevnetGauntletTest < ActiveSupport::TestCase
  G = Release::DevnetGauntlet
  RECORD = { "occurred_at" => "2026-10-11T15:00:00Z", "actor" => "turf_monster", "metadata" => {} }.freeze

  test "only a Turf repo owes the gauntlet" do
    assert G.required?(%w[mcritchie-studio turf-monster])
    assert G.required?(%w[turf-vault])
    refute G.required?(%w[mcritchie-studio studio-engine rolio])
    assert_equal [:not_required, nil], G.verdict(repos: %w[mcritchie-studio], snapshot: {})
  end

  test "a Turf release with a recorded gauntlet ships and says so" do
    verdict, message = G.verdict(repos: %w[turf-monster], snapshot: { G::STEP => RECORD })

    assert_equal :recorded, verdict
    assert_equal "devnet gauntlet recorded 2026-10-11T15:00:00Z by turf_monster for turf-monster", message
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
    assert_equal :recorded, G.verdict(repos: %w[turf-vault], snapshot: { G::STEP => RECORD }, waiver: "x").first
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
                          model: "claude-opus", tokens_in: 1, tokens_out: 1, cost: 0,
                          metadata: { "contest" => "qa-rehearsal-1" })
    recorded = read.call(release)[G::STEP]
    assert_equal "turf_monster", recorded["actor"]
    assert_equal "qa-rehearsal-1", recorded.dig("metadata", "contest")
    assert_equal :recorded, G.verdict(repos: %w[turf-monster], snapshot: read.call(release)).first
  end
end
