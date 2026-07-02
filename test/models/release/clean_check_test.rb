require "test_helper"

# Pure decision logic for the clean-release GUARD behind `Deploy with Task`
# (`bin/release status --clean-only`). No git/board/network here — same IO-free
# contract as MergePlan/ShipSequence, so it's trivially unit-tested and the shell
# stays thin. The two signals (assembled tasks + release-ahead-of-main) are
# gathered by bin/release; this only decides clean vs dirty and writes the message.
class Release::CleanCheckTest < ActiveSupport::TestCase
  C = Release::CleanCheck

  # --- clean: release == main (nothing else pending) -----------------------

  test "clean when there are no pending tasks and no repo is ahead of main" do
    v = C.evaluate(pending_tasks: [], repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }])
    assert v["clean"]
    assert_empty v["pending_tasks"]
    assert_empty v["ahead_repos"]
    assert_includes v["message"], "release == main"
    assert_includes v["message"], "Deploy with Task"
  end

  test "clean when both signals are empty" do
    v = C.evaluate
    assert v["clean"]
    assert_includes v["message"], "safe to expedite one task"
  end

  # --- dirty via the BOARD signal (assembled-but-unshipped tasks) ----------

  test "dirty when a task is already assembled and pending ship" do
    v = C.evaluate(
      pending_tasks: [{ "slug" => "other-work", "title" => "Some other feature" }],
      repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]
    )
    refute v["clean"]
    assert_equal ["other-work"], v["pending_tasks"].map { |t| t["slug"] }
  end

  test "the dirty message REFUSES and OFFERS Merge, Assemble, Deploy, listing the pending task" do
    v = C.evaluate(pending_tasks: [{ "slug" => "other-work", "title" => "Some other feature" }])
    msg = v["message"]
    assert_includes msg, "refused", "the guard refuses on a dirty release"
    assert_includes msg, "Merge, Assemble, Deploy", "it offers shipping the whole release instead"
    assert_includes msg, "other-work", "it lists the pending task slug"
    assert_includes msg, "Some other feature", "it lists the pending task title"
    refute_includes msg, "safe to expedite"
  end

  test "a pending task with no title is listed by slug alone (no trailing dash)" do
    v = C.evaluate(pending_tasks: [{ "slug" => "bare-slug", "title" => "" }])
    assert_includes v["message"], "- bare-slug"
    refute_includes v["message"], "bare-slug —"
  end

  # --- dirty via the GIT signal (release ahead of main) --------------------

  test "dirty when a repo's release is ahead of main even with no assembled task" do
    v = C.evaluate(
      pending_tasks: [],
      repo_states: [
        { "repo" => "mcritchie-studio", "ahead" => 2 },
        { "repo" => "turf-monster", "ahead" => 0 }
      ]
    )
    refute v["clean"], "a stray commit on release with no task is still dirty (fail-closed)"
    assert_equal [{ "repo" => "mcritchie-studio", "ahead" => 2 }], v["ahead_repos"]
    assert_includes v["message"], "mcritchie-studio (+2)"
    assert_includes v["message"], "Merge, Assemble, Deploy"
  end

  test "ahead_repos excludes repos that are even with main" do
    v = C.evaluate(repo_states: [
      { "repo" => "a", "ahead" => 0 },
      { "repo" => "b", "ahead" => 3 },
      { "repo" => "c", "ahead" => 0 }
    ])
    assert_equal ["b"], v["ahead_repos"].map { |r| r["repo"] }
  end

  # --- normalization / robustness ------------------------------------------

  test "tolerates symbol keys from a board payload" do
    v = C.evaluate(pending_tasks: [{ slug: "sym-task", title: "Symbol keyed" }])
    refute v["clean"]
    assert_equal "sym-task", v["pending_tasks"].first["slug"]
    assert_equal "Symbol keyed", v["pending_tasks"].first["title"]
  end

  test "coerces a string ahead count from a shell read" do
    v = C.evaluate(repo_states: [{ "repo" => "r", "ahead" => "4" }])
    refute v["clean"]
    assert_equal 4, v["ahead_repos"].first["ahead"]
  end

  test "the verdict is JSON round-trippable (string keys, plain values)" do
    v = C.evaluate(pending_tasks: [{ "slug" => "x", "title" => "y" }])
    assert_equal v, JSON.parse(v.to_json)
  end
end
