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

  # THE FALSE REFUSAL THIS RULE WOULD OTHERWISE SHIP WITH. A `library` task names its
  # gem plus the CONSUMERS that adopt it, and carries ONE PR — the gem's. The
  # consumer's change in a gem release is committed by the pipeline itself
  # (bump_consumer_locks_for_qa), so there is no consumer PR url that could ever be
  # recorded. Without the exemption, guard-engine-migration-rollback — a real
  # shipped task naming four repos behind one studio-engine PR — would have been
  # refused, and so would every engine release after it.
  test "[unit] repo_coverage_gap exempts a GEM release naming its consumers" do
    assert_empty Release::SweepPlan.repo_coverage_gap(
      repos: %w[studio-engine mcritchie-studio turf-monster mcritchie-industries],
      pr_repos: ["studio-engine"],
      kind: "gem"
    )
  end

  test "[unit] repo_coverage_gap still refuses the SAME repos when the member is an app" do
    # The control for the exemption above: nothing about the repo list earns the
    # pass — only the gem kind does. An app member with the identical shape is the
    # 2026-08-13 incident and must still be refused.
    assert_equal %w[mcritchie-studio turf-monster mcritchie-industries],
                 Release::SweepPlan.repo_coverage_gap(
                   repos: %w[studio-engine mcritchie-studio turf-monster mcritchie-industries],
                   pr_repos: ["studio-engine"],
                   kind: "app"
                 )
  end

  test "[unit] compute does not block a gem row, and still blocks an app row beside it" do
    gem_row = row("bump-studio-engine", merged: "accepted", repo: "studio-engine")
                .merge("kind" => "gem",
                       "repos" => %w[studio-engine mcritchie-studio turf-monster],
                       "pr_urls" => { "studio-engine" => "https://github.com/McRitchie-Studio/studio-engine/pull/124" })
    app_row = row("land-rails-security-patch", merged: "accepted", repo: "mcritchie-studio")
                .merge("kind" => "app",
                       "repos" => %w[mcritchie-studio turf-monster],
                       "pr_urls" => { "mcritchie-studio" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836" })

    plan = Release::SweepPlan.compute([ gem_row, app_row ])

    assert_equal ["land-rails-security-patch"], plan["blocked"].map { |b| b["slug"] }
    assert_equal ["bump-studio-engine"], plan["sweep"], "the gem release rides"
  end

  test "[unit] a row with NO kind is judged as an app — the fail-CLOSED default" do
    legacy = row("land-rails-security-patch", merged: "accepted", repo: "mcritchie-studio")
               .merge("repos" => %w[mcritchie-studio turf-monster],
                      "pr_urls" => { "mcritchie-studio" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836" })

    assert_equal ["land-rails-security-patch"], Release::SweepPlan.compute([legacy])["blocked"].map { |b| b["slug"] }
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

  # --- the PARKED-repo hold (sweep-ignores-parked-repos) -----------------------
  #
  # A registered repo whose ladder is anything but three-rung (rolio `dormant`,
  # tax-studio `planned`, chain-ops `blocked`) is not the conductor's to promote or
  # deploy. Before this partition the sweep took every `reviewed` task with no repo
  # filter, so a task naming a parked repo would have been promoted and deployed.
  # It is now HELD: kept out of record/sweep, reported with its repo and ladder, and
  # left in its stage. The map is a fixture — these tests pin the RULE, not which
  # real repos happen to be parked today.
  PARKED = { "parked-app" => "dormant", "future-app" => "planned" }.freeze

  def parked_row(slug, repos:, merged: "accepted", stage: "reviewed")
    row(slug, merged: merged, stage: stage, repo: repos.first)
      .merge("repos" => repos, "pr_urls" => repos.to_h { |r| [ r, "https://github.com/McRitchie-Studio/#{r}/pull/1" ] })
  end

  test "[unit] a row naming a parked repo is HELD off the sweep, naming the repo and its ladder" do
    plan = Release::SweepPlan.compute([ parked_row("rolio-feature", repos: ["parked-app"]), row("hub-feature") ],
                                      parked: PARKED)

    assert_equal ["hub-feature"], plan["sweep"], "the neighbour still rides"
    refute_includes plan["record"].map { |r| r["slug"] }, "rolio-feature"
    assert_empty plan["held"], "a parked hold is its own partition, not the unstamped-merge anomaly"
    assert_equal [ { "slug" => "rolio-feature", "stage" => "reviewed", "repos" => ["parked-app"],
                     "parked" => { "parked-app" => "dormant" }, "live" => [] } ],
                 plan["parked"]
  end

  test "[unit] a MIXED row (one live repo, one parked) holds the WHOLE task, never the live half" do
    mixed = parked_row("span-hub-and-rolio", repos: %w[mcritchie-studio parked-app])

    plan = Release::SweepPlan.compute([ mixed ], parked: PARKED)

    assert_empty plan["sweep"], "half-shipping a task breaks the assembled invariant — the whole task holds"
    assert_equal ["mcritchie-studio"], plan["parked"].first["live"]
    assert_equal({ "parked-app" => "dormant" }, plan["parked"].first["parked"])
  end

  test "[unit] a parked row is held BEFORE the coverage refusal — it cannot abort a sweep it is not in" do
    # Names two repos with a PR for only one: on its own this is the 2026-08-13
    # refusal, which aborts the whole run. But a task naming a parked repo is not a
    # member of this sweep at all, so it has no promote to be wrong about.
    incomplete = row("span-hub-and-rolio", merged: "accepted")
                   .merge("repos" => %w[mcritchie-studio parked-app],
                          "pr_urls" => { "mcritchie-studio" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/2" })

    plan = Release::SweepPlan.compute([ incomplete ], parked: PARKED)

    assert_empty plan["blocked"]
    assert_equal ["span-hub-and-rolio"], plan["parked"].map { |p| p["slug"] }
  end

  test "[unit] an unstamped row on a parked repo reports as parked, not as the merge anomaly" do
    plan = Release::SweepPlan.compute([ parked_row("rolio-unstamped", repos: ["parked-app"], merged: "") ],
                                      parked: PARKED)

    assert_empty plan["held"]
    assert_equal ["rolio-unstamped"], plan["parked"].map { |p| p["slug"] }
  end

  # The control: the hold must be CAUSED by the ladder map. The identical row with
  # no parked repos declared sweeps, so the partition above is not an accident of
  # the row's shape.
  test "[unit] CONTROL: the same row sweeps when no repo it names is parked" do
    plan = Release::SweepPlan.compute([ parked_row("rolio-feature", repos: ["parked-app"]) ], parked: {})

    assert_equal ["rolio-feature"], plan["sweep"]
    assert_empty plan["parked"]
  end

  test "[unit] parked_hold_line names the task, the parked repo, its ladder and the stage it keeps" do
    line = Release::SweepPlan.parked_hold_line(
      "slug" => "rolio-feature", "stage" => "reviewed", "parked" => { "parked-app" => "dormant" }, "live" => []
    )

    assert_includes line, "HELD rolio-feature"
    assert_includes line, "parked-app (ladder: dormant)"
    assert_includes line, "left `reviewed`"
    assert_includes line, "never promoted or deployed"
  end

  test "[unit] parked_hold_line on a mixed task says why its live repo does not ride either" do
    line = Release::SweepPlan.parked_hold_line(
      "slug" => "span", "stage" => "assembled", "parked" => { "future-app" => "planned" }, "live" => ["mcritchie-studio"]
    )

    assert_includes line, "future-app (ladder: planned)"
    assert_includes line, "whole task"
    assert_includes line, "mcritchie-studio"
    assert_includes line, "left `assembled`", "a straggler keeps ITS stage, not `reviewed`"
  end
end
