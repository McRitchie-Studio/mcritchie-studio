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

  # --- the multi-repo PR-coverage refusal (the 2026-08-13 half-ship) ---

  test "[unit] repo_coverage_gap names the repo a multi-repo task recorded no PR for" do
    assert_equal ["turf-monster"],
                 Release::SweepPlan.repo_coverage_gap(
                   repos: %w[mcritchie-studio turf-monster],
                   pr_repos: ["mcritchie-studio"]
                 )
  end

  test "[unit] repo_coverage_gap passes a multi-repo task with a PR per repo" do
    assert_empty Release::SweepPlan.repo_coverage_gap(
      repos: %w[mcritchie-studio turf-monster],
      pr_repos: %w[turf-monster mcritchie-studio]
    )
  end

  test "[unit] repo_coverage_gap never fires on a single-repo task, PR or no PR" do
    # A single-repo task cannot lose a repo it never had a second of; its missing
    # PR is the review lane's problem, not the sweep's.
    assert_empty Release::SweepPlan.repo_coverage_gap(repos: ["mcritchie-studio"], pr_repos: [])
    assert_empty Release::SweepPlan.repo_coverage_gap(repos: [], pr_repos: [])
  end

  test "[unit] compute BLOCKS the incident row and keeps it out of record/sweep" do
    # THE regression: repositories [hub, turf] with only the hub's PR url. Before
    # this, the row swept normally, the promote saw one repo, and the task was
    # stamped assembled then shipped for a repo that never left `accepted`.
    incident = row("land-rails-security-patch", merged: "accepted",
                   pr_url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836",
                   repo: "mcritchie-studio")
                 .merge("repos" => %w[mcritchie-studio turf-monster],
                        "pr_urls" => { "mcritchie-studio" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836" })

    plan = Release::SweepPlan.compute([incident, row("healthy-single-repo-task")])

    assert_equal ["land-rails-security-patch"], plan["blocked"].map { |b| b["slug"] }
    assert_equal ["turf-monster"], plan["blocked"].first["missing"]
    assert_equal ["healthy-single-repo-task"], plan["sweep"],
                 "the blocked row must not ride, and must not take its neighbours with it"
    refute_includes plan["record"].map { |r| r["slug"] }, "land-rails-security-patch"
  end

  test "[unit] compute clears the block once every repo has its PR recorded" do
    healed = row("land-rails-security-patch", merged: "accepted")
               .merge("repos" => %w[mcritchie-studio turf-monster],
                      "pr_urls" => {
                        "mcritchie-studio" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836",
                        "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/305"
                      })

    plan = Release::SweepPlan.compute([healed])

    assert_empty plan["blocked"]
    assert_equal ["land-rails-security-patch"], plan["sweep"]
  end

  test "[unit] a row carrying only the singular repo/pr_url still normalizes and passes" do
    # Back-compat: an older caller emitting {slug,stage,merged,pr_url,repo} has no
    # plural pair, and must not be refused for lacking a field it never sent.
    plan = Release::SweepPlan.compute([row("legacy-shaped-row")])

    assert_empty plan["blocked"]
    assert_equal ["legacy-shaped-row"], plan["sweep"]
  end
end
