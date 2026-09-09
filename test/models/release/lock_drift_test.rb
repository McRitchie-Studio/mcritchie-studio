require "test_helper"

# THERE IS NO VERSION LITERAL IN THIS FILE THAT THE GUARD READS.
#
# Every version below is a fixture the test itself supplies on BOTH sides of the
# comparison — the resolution map AND the published anchor — so no number here can
# go stale when solana-studio publishes again. That is deliberate and it is the
# property under test: the guard asserts a RELATION between what a repo resolved
# and what the sweep just published, never a floor somebody has to remember to
# bump. A test reading `assert ... >= "0.9.1"` would be the defect it is guarding
# against, wearing a passing badge.
class Release::LockDriftTest < ActiveSupport::TestCase
  ENGINE   = "studio-engine".freeze
  CONSUMER = "turf-monster".freeze
  GEM      = "solana-studio".freeze

  # --- MUTATION 1: make the engine TRAIL — this test must REDDEN ---------------
  #
  # The live defect, in miniature: the sweep published a version, the engine's own
  # lock stayed on the one before it, and nothing in the sweep noticed. Break
  # bump_producer_locks_for_accepted (or delete its call) and this is the test
  # that goes red.
  test "trailing flags the engine when its lock resolves older than the published gem" do
    findings = Release::LockDrift.trailing(
      { ENGINE => { GEM => "0.9.0" }, CONSUMER => { GEM => "0.9.1" } },
      { GEM => "0.9.1" }
    )

    assert_equal 1, findings.size, "expected exactly the engine to be flagged, got #{findings.inspect}"
    assert_equal ENGINE, findings.first["repo"]
    assert_equal GEM,    findings.first["gem"]
    assert_equal "0.9.0", findings.first["resolved"]
    assert_equal "0.9.1", findings.first["published"]
    assert_not Release::LockDrift.aligned?(
      { ENGINE => { GEM => "0.9.0" } }, { GEM => "0.9.1" }
    )
  end

  test "message names the trailing repo, both versions, and refuses a re-push" do
    findings = Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.0" } }, { GEM => "0.9.1" })
    message  = Release::LockDrift.message(findings)

    assert_includes message, ENGINE
    assert_includes message, "0.9.0"
    assert_includes message, "0.9.1"
    assert_includes message, "ALREADY PUBLISHED"
  end

  # --- MUTATION 2: make the engine LEAD — this test must STAY GREEN ------------
  #
  # THE ONE THAT PROVES THE FLOOR IS THE PUBLISHED VERSION AND NOT THE MAX
  # RESOLVED. The engine is the producer and may legitimately resolve an
  # UNRELEASED solana-studio (a path:/git: checkout of the gem it is developing
  # against) while every consumer sits exactly where the sweep just put them.
  #
  # Anchor the floor on max(resolved) instead and this test goes red on
  # turf-monster — a repo that is correctly bumped and has done nothing wrong.
  # That failure would be the guard firing spuriously, which is precisely the
  # difference between asserting a relation and asserting a direction.
  test "trailing stays silent when the engine LEADS the published gem" do
    resolutions = { ENGINE => { GEM => "0.10.0" }, CONSUMER => { GEM => "0.9.1" } }

    assert_empty Release::LockDrift.trailing(resolutions, { GEM => "0.9.1" }),
                 "a producer resolving an unreleased gem is not drift, and a consumer sitting at " \
                 "the published version must never be flagged for it"
    assert Release::LockDrift.aligned?(resolutions, { GEM => "0.9.1" })
  end

  test "a repo resting exactly on the published version is not trailing" do
    assert_empty Release::LockDrift.trailing(
      { ENGINE => { GEM => "0.9.1" }, CONSUMER => { GEM => "0.9.1" } },
      { GEM => "0.9.1" }
    )
  end

  # --- the skips, each for a different reason ---------------------------------

  test "a repo that does not bundle the gem is skipped, not flagged" do
    assert_empty Release::LockDrift.trailing(
      { "mcritchie-studio" => { GEM => nil }, "rolio" => {} },
      { GEM => "0.9.1" }
    )
  end

  test "a blank published version is skipped whole — an unknown anchor proves nothing" do
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.0" } }, { GEM => "" })
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.0" } }, { GEM => nil })
  end

  test "an unparseable version on either side is skipped rather than aborting the sweep" do
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "not-a-version" } }, { GEM => "0.9.1" })
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.0" } }, { GEM => "not-a-version" })
  end

  test "no published gems means nothing to compare" do
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.0" } }, {})
    assert Release::LockDrift.aligned?({ ENGINE => { GEM => "0.9.0" } }, {})
  end

  # --- the relation holds across gems and repos, and orders stably ------------

  test "trailing compares every published gem against every repo" do
    findings = Release::LockDrift.trailing(
      {
        ENGINE => { GEM => "0.9.0", "studio-engine" => nil },
        CONSUMER => { GEM => "0.9.1", "studio-engine" => "0.74.0" },
        "rolio" => { "studio-engine" => "0.74.4" }
      },
      { GEM => "0.9.1", "studio-engine" => "0.74.4" }
    )

    assert_equal [ [ ENGINE, GEM ], [ CONSUMER, "studio-engine" ] ],
                 findings.map { |f| [ f["repo"], f["gem"] ] }
  end

  test "version comparison is semantic, not lexical" do
    # "0.10.0" < "0.9.1" as STRINGS; as versions it leads. A lexical compare here
    # would flag a repo that is ahead — the spurious fire mutation 2 guards.
    assert_empty Release::LockDrift.trailing({ ENGINE => { GEM => "0.10.0" } }, { GEM => "0.9.1" })
    # And the same pair inverted really is drift.
    assert_equal 1, Release::LockDrift.trailing({ ENGINE => { GEM => "0.9.1" } }, { GEM => "0.10.0" }).size
  end
end
