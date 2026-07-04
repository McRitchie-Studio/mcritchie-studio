# frozen_string_literal: true

require "test_helper"

# Release::SweepPlan is the PURE per-task sweep decision behind `bin/release
# prepare`'s self-healing sweep and `bin/release merge`'s crash-recovery skip:
# given the detected candidate rows it decides gh-merge vs skip (already merged:
# release/main) vs leave-behind (no PR). Rails-free (bin/release loads it
# standalone), so these are plain in-process unit tests.
class Release::SweepPlanTest < ActiveSupport::TestCase
  def row(slug, stage: "reviewed", merged: "", pr_url: "https://github.com/x/y/pull/#{slug.sum}", repo: "mcritchie-studio")
    { "slug" => slug, "stage" => stage, "merged" => merged, "pr_url" => pr_url, "repo" => repo }
  end

  test "[unit] a fresh reviewed task with a PR goes to the merge list and the sweep list" do
    plan = Release::SweepPlan.compute([row("task-a", pr_url: "https://github.com/x/y/pull/1")])

    assert_equal [{ "pr_url" => "https://github.com/x/y/pull/1", "slugs" => ["task-a"] }], plan["merge"]
    assert_empty plan["skip"]
    assert_empty plan["unmergeable"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a merged:release task SKIPS the gh merge but still sweeps (interrupted Steffon)" do
    plan = Release::SweepPlan.compute([row("task-a", merged: "release")])

    assert_empty plan["merge"], "never re-merge a PR already riding release"
    assert_equal [{ "slug" => "task-a", "merged" => "release" }], plan["skip"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a merged:main task also skips — never regressed by a re-run (interrupted Avi)" do
    plan = Release::SweepPlan.compute([row("task-a", stage: "assembled", merged: "main")])

    assert_empty plan["merge"]
    assert_equal [{ "slug" => "task-a", "merged" => "main" }], plan["skip"]
    assert_equal ["task-a"], plan["sweep"]
  end

  test "[unit] a task with no PR and nothing merged is unmergeable — left off the sweep" do
    plan = Release::SweepPlan.compute([row("task-a", pr_url: "")])

    assert_empty plan["merge"]
    assert_empty plan["skip"]
    assert_equal ["task-a"], plan["unmergeable"]
    assert_empty plan["sweep"], "nothing to merge and nothing merged → it stays reviewed"
  end

  test "[unit] several task records riding ONE PR are grouped — the PR merges once, every rider sweeps" do
    plan = Release::SweepPlan.compute([
      row("task-a", pr_url: "https://github.com/x/y/pull/7"),
      row("task-b", pr_url: "https://github.com/x/y/pull/7")
    ])

    assert_equal [{ "pr_url" => "https://github.com/x/y/pull/7", "slugs" => %w[task-a task-b] }], plan["merge"]
    assert_equal %w[task-a task-b], plan["sweep"]
  end

  test "[unit] a mixed batch partitions correctly, sweep order = skips first then merges" do
    plan = Release::SweepPlan.compute([
      row("fresh", pr_url: "https://github.com/x/y/pull/1"),
      row("swept", merged: "release"),
      row("naked", pr_url: "")
    ])

    assert_equal ["fresh"], plan["merge"].flat_map { |g| g["slugs"] }
    assert_equal ["swept"], plan["skip"].map { |r| r["slug"] }
    assert_equal ["naked"], plan["unmergeable"]
    assert_equal %w[swept fresh], plan["sweep"], "skips (nothing to do in git) record ahead of fresh merges"
  end

  test "[unit] an empty detection computes an empty plan (the idempotent no-op shape)" do
    plan = Release::SweepPlan.compute([])

    assert_empty plan["merge"]
    assert_empty plan["skip"]
    assert_empty plan["unmergeable"]
    assert_empty plan["sweep"]
  end

  test "[unit] rows normalize nils safely (a nil merged/pr_url reads as absent)" do
    plan = Release::SweepPlan.compute([{ "slug" => "task-a", "stage" => "reviewed", "merged" => nil, "pr_url" => nil }])

    assert_equal ["task-a"], plan["unmergeable"]
  end
end
