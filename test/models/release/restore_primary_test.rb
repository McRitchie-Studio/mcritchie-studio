require "test_helper"

# Pure decision logic for `bin/agent-worktree restore-primary` — the COMPLEMENT of
# Release::ShipSequence.preflight_offenders. No git/fetch/checkout here: same
# IO-free contract as ShipSequence, so the never-discard-work safety rule is
# trivially unit tested and the shell stays thin.
class Release::RestorePrimaryTest < ActiveSupport::TestCase
  R = Release::RestorePrimary

  # --- refuse: never discard uncommitted work ------------------------------

  test "refuses a dirty tree (uncommitted changes)" do
    plan = R.decision("branch" => "main", "dirty_files" => ["db/schema.rb"], "unpushed" => [])
    assert_equal "refuse", plan["action"]
    assert R.refuse?(plan)
    assert_equal ["db/schema.rb"], plan["dirty_files"]
    assert(plan["reasons"].any? { |r| r.include?("uncommitted") })
  end

  test "refuses even when on main if the tree is dirty" do
    # Mirrors ShipSequence: on-main is NOT enough — a dirty main is still an offender.
    plan = R.decision("branch" => "main", "dirty_files" => ["app/foo.rb"])
    assert_equal "refuse", plan["action"]
  end

  # --- refuse: never discard unpushed commits ------------------------------

  test "refuses unpushed commits (work on no remote)" do
    plan = R.decision("branch" => "pr-181", "dirty_files" => [], "unpushed" => ["abc123 wip"])
    assert_equal "refuse", plan["action"]
    assert_equal ["abc123 wip"], plan["unpushed"]
    assert(plan["reasons"].any? { |r| r.include?("unpushed") })
  end

  test "refusal names both reasons when dirty AND unpushed" do
    plan = R.decision("branch" => "pr-9", "dirty_files" => ["a.rb"], "unpushed" => ["d4 wip"])
    assert_equal "refuse", plan["action"]
    assert_equal 2, plan["reasons"].size
  end

  # --- restore: fast-forward when clean ------------------------------------

  test "restores a clean checkout drifted onto a review branch" do
    plan = R.decision("branch" => "pr-181", "dirty_files" => [], "unpushed" => [])
    assert_equal "restore", plan["action"]
    assert_equal "main", plan["branch"]
    assert_equal "pr-181", plan["from_branch"]
    refute plan["already_on_canonical"]
  end

  test "a clean checkout already on main is a restore flagged already_on_canonical" do
    # Still a restore (so the caller ff's main up to origin), but no branch switch.
    plan = R.decision("branch" => "main", "dirty_files" => [], "unpushed" => [])
    assert_equal "restore", plan["action"]
    assert plan["already_on_canonical"]
  end

  test "missing dirty_files/unpushed keys default to clean (restore)" do
    plan = R.decision("branch" => "main")
    assert_equal "restore", plan["action"]
  end

  test "accepts symbol-keyed state (record side)" do
    plan = R.decision(branch: "pr-7", dirty_files: [], unpushed: [])
    assert_equal "restore", plan["action"]
    assert_equal "pr-7", plan["from_branch"]
  end

  # --- detect + fix agree (the ShipSequence contract) ----------------------

  test "the canonical branch matches ShipSequence's on_main definition" do
    # An off-main but clean checkout is an OFFENDER for ShipSequence (it must be
    # fixed) and a RESTORE for us (we fix it) — detect and fix agree on `main`.
    state = { "repo" => "mcritchie-studio", "branch" => "pr-181", "dirty_files" => [] }
    offenders = Release::ShipSequence.preflight_offenders([state])
    assert_equal 1, offenders.size, "ShipSequence flags an off-main checkout as an offender"

    plan = R.decision(state.merge("unpushed" => []))
    assert_equal "restore", plan["action"]
    assert_equal "main", plan["branch"]
  end

  # --- refusal_message: loud + actionable ----------------------------------

  test "refusal_message names the app, reasons, files, and the fix" do
    plan = R.decision("branch" => "pr-3", "dirty_files" => %w[a.rb b.rb], "unpushed" => ["e1 wip"])
    msg = R.refusal_message("mcritchie-studio", plan)
    assert_match(/refusing to restore mcritchie-studio/, msg)
    assert_match(/uncommitted: a\.rb, b\.rb/, msg)
    assert_match(/unpushed:.*e1 wip/, msg)
    assert_match(/Resolve by hand/, msg)
  end

  test "refusal_message truncates a long file list with a (+N more) tail" do
    files = (1..8).map { |i| "f#{i}.rb" }
    plan = R.decision("branch" => "main", "dirty_files" => files, "unpushed" => [])
    msg = R.refusal_message("turf-monster", plan)
    assert_match(/f1\.rb, f2\.rb, f3\.rb, f4\.rb, f5\.rb \(\+3 more\)/, msg)
  end
end
