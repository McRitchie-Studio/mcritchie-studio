# frozen_string_literal: true

require "test_helper"

# Release::SweepPlan is the PURE per-task sweep partition behind `bin/release
# prepare`'s self-healing sweep and `bin/release merge`. In the accepted-ladder,
# review already merged each feat PR into `accepted` (merged:"accepted"), so the
# sweep no longer decides "which PRs to merge" — it partitions the candidates into
# the members to RECORD onto the RC (code on accepted/release/main) versus the HELD
# anomalies (a `reviewed` member with no merged stamp — review's merge never
# landed). Rails-free (bin/release loads it standalone), so these are plain
# in-process unit tests.
class Release::SweepPlanTest < ActiveSupport::TestCase
  def row(slug, stage: "reviewed", merged: "accepted", pr_url: "https://github.com/x/y/pull/#{slug.sum}", repo: "mcritchie-studio")
    { "slug" => slug, "stage" => stage, "merged" => merged, "pr_url" => pr_url, "repo" => repo }
  end

  test "[unit] a reviewed member merged:accepted is recorded and swept (the ladder's first rung)" do
    plan = Release::SweepPlan.compute([row("task-a", merged: "accepted")])

    assert_equal [{ "slug" => "task-a", "merged" => "accepted" }], plan["record"]
    assert_empty plan["held"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a merged:release member records + sweeps (interrupted Steffon crash recovery)" do
    plan = Release::SweepPlan.compute([row("task-a", merged: "release")])

    assert_equal [{ "slug" => "task-a", "merged" => "release" }], plan["record"]
    assert_empty plan["held"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a merged:main member also records — never regressed by a re-run (interrupted Avi)" do
    plan = Release::SweepPlan.compute([row("task-a", stage: "assembled", merged: "main")])

    assert_equal [{ "slug" => "task-a", "merged" => "main" }], plan["record"]
    assert_empty plan["held"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a reviewed member with NO merged stamp is HELD — left off the sweep (anomaly)" do
    # merged:"" means review's feat→accepted merge never landed: there is no code on
    # accepted to promote, so it is not recorded onto the RC. It self-heals on re-review.
    plan = Release::SweepPlan.compute([row("task-a", merged: "")])

    assert_empty plan["record"]
    assert_equal ["task-a"], plan["held"]
    assert_empty plan["sweep"], "an unstamped reviewed member is never swept onto the RC"
  end

  test "[unit] a mixed batch partitions correctly, sweep = record order (held excluded)" do
    plan = Release::SweepPlan.compute([
      row("fresh", merged: "accepted"),
      row("swept", merged: "release"),
      row("naked", merged: "")
    ])

    assert_equal %w[fresh swept], plan["record"].map { |r| r["slug"] }
    assert_equal ["naked"], plan["held"]
    assert_equal %w[fresh swept], plan["sweep"], "held anomalies never enter the sweep"
  end

  test "[unit] an empty detection computes an empty plan (the idempotent no-op shape)" do
    plan = Release::SweepPlan.compute([])

    assert_empty plan["record"]
    assert_empty plan["held"]
    assert_empty plan["sweep"]
  end

  test "[unit] rows normalize nils safely (a nil merged reads as absent → held)" do
    plan = Release::SweepPlan.compute([{ "slug" => "task-a", "stage" => "reviewed", "merged" => nil, "pr_url" => nil }])

    assert_equal ["task-a"], plan["held"]
    assert_empty plan["sweep"]
  end

  # --- base_action: the accepted→release batch-PR base assertion ---------------

  test "[unit] base_action proceeds on a release-based batch PR (correct base)" do
    assert_equal :proceed, Release::SweepPlan.base_action("release", "release")
  end

  test "[unit] base_action ABORTS any non-release base — including the retired accepted arm" do
    # The :retarget arm is GONE: review merges feat→accepted, so the sweep never sees
    # an accepted-based feat PR to retarget. The only valid batch-PR base is release.
    assert_equal :abort, Release::SweepPlan.base_action("accepted", "release")
    assert_equal :abort, Release::SweepPlan.base_action("main", "release")
    assert_equal :abort, Release::SweepPlan.base_action("feat/whatever", "release")
  end

  test "[unit] base_action treats a blank/whitespace base as abort — never passes as release" do
    assert_equal :abort, Release::SweepPlan.base_action("", "release")
    assert_equal :abort, Release::SweepPlan.base_action("  ", "release")
  end

  test "[unit] base_action trims surrounding whitespace before matching" do
    assert_equal :proceed, Release::SweepPlan.base_action(" release ", "release")
    assert_equal :abort,   Release::SweepPlan.base_action("accepted\n", "release")
  end
end
