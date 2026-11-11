# frozen_string_literal: true

require "test_helper"

# Release::Preflight: the read-only refusals `bin/release prepare` makes before its
# first write (task release-preflight-hardening). Rails-free, so plain unit tests.
class Release::PreflightTest < ActiveSupport::TestCase
  HUB = "/Users/x/projects/mcritchie-studio"

  def clear(**over)
    { blocked: [], unreadable: [], identity: "github.mcritchie-agent", free_slots: 4, cwd: HUB, roots: [HUB] }.merge(over)
  end

  test "[unit] a clear release has no refusals" do
    assert_empty Release::Preflight.refusals(**clear)
  end

  test "[unit] preflight refusals: a member card naming a repo with no PR" do
    blocked = [{ "slug" => "prisoners-dilemma", "repos" => %w[a b c d e f g h i], "missing" => %w[g h i] }]
    lines = Release::Preflight.refusals(**clear(blocked: blocked))

    assert_equal 1, lines.size
    assert_includes lines.first, "member prisoners-dilemma names 9 repos but has no PR for 3: g, h, i"
    assert_includes lines.first, "--remove-repo"
  end

  test "[unit] preflight refusals: a repo the GitHub App cannot read" do
    lines = Release::Preflight.refusals(**clear(identity: "github.mcritchie-admin",
                                                unreadable: [["voicebox", "GraphQL: Resource not accessible by integration"]]))

    assert_equal 1, lines.size
    assert_includes lines.first, "the GitHub App github.mcritchie-admin cannot read voicebox"
    assert_includes lines.first, "Resource not accessible"
  end

  test "[unit] preflight refusals: no free desk slot, and an unread count is not a refusal" do
    assert_match(/no free desk slot/, Release::Preflight.refusals(**clear(free_slots: 0)).first)
    assert_empty Release::Preflight.refusals(**clear(free_slots: nil))
  end

  test "[unit] preflight refusals: a cwd outside the hub, and a cwd inside it passes" do
    line = Release::Preflight.refusals(**clear(cwd: "/Users/x/projects")).first

    assert_includes line, "wrong cwd: /Users/x/projects"
    assert_includes line, "cd #{HUB}"
    assert_empty Release::Preflight.refusals(**clear(cwd: "#{HUB}/bin"))
    refute_empty Release::Preflight.refusals(**clear(cwd: "#{HUB}-other")), "a sibling prefix is not inside"
  end

  test "[unit] every finding is reported at once, one line each" do
    lines = Release::Preflight.refusals(
      **clear(blocked: [{ "slug" => "t", "repos" => %w[a b], "missing" => ["b"] }],
              unreadable: [["voicebox", "denied"]], free_slots: 0, cwd: "/tmp")
    )

    assert_equal 4, lines.size
    message = Release::Preflight.message(lines)
    assert_match(/\Arelease preflight refused \(4\) — NOTHING was claimed/, message)
    assert_equal 4, message.scan("\n  - ").size
  end

  test "[unit] release_repos spans candidates and the active release, once each" do
    rows = [{ "repos" => %w[mcritchie-studio voicebox] }, { "repo" => "turf-monster", "repos" => [] }]

    assert_equal %w[mcritchie-studio voicebox turf-monster studio-engine],
                 Release::Preflight.release_repos(rows, %w[voicebox studio-engine])
  end
end
