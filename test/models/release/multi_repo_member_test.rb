# frozen_string_literal: true

require "test_helper"

# THE 2026-08-13 HALF-SHIP, and the guards that close it.
#
# `land-rails-security-patch` named two repos (mcritchie-studio, turf-monster) and
# carried the HUB's PR url — the only PR slot a task had. Every release stage read
# the singular Task#release_repo, which parses that url, so the promote list, the
# member plan, the repo plan, the pre-QA gate, the QA deploy and the ship all saw
# ONE repo. Turf was never promoted. The task was stamped `assembled`, then
# `shipped`, then `merged: "main"` — while turf production still ran the unpatched
# code. The board asserted a security patch reached production on a repo whose
# `main` had not moved.
#
# These tests assert the EFFECT, not the plan. A test that only checks "the repo
# plan is computed" passes against the broken code: the plan WAS computed,
# correctly, from the wrong field. So every guard here is driven by MUTATING the
# release — landing evidence for one repo and not the other — and asserting the
# member's STAGE and `merged` stamp.
class Release::MultiRepoMemberTest < ActiveSupport::TestCase
  HUB  = "mcritchie-studio"
  TURF = "turf-monster"
  HUB_PR  = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

  # The incident's exact task shape: two repos, a PR url per repo, `reviewed` and
  # ready to ride.
  def two_repo_task(label = "security")
    Task.create!(
      title: "land rails #{label} patch",
      stage: "reviewed",
      metadata: { "devops" => {
        "shape" => "backend",
        "repositories" => [ HUB, TURF ],
        "pr_url" => HUB_PR,
        "pr_urls" => { HUB => HUB_PR, TURF => TURF_PR }
      } }
    )
  end

  def single_repo_task(label = "hub", repo: HUB)
    Task.create!(title: "single repo #{label} task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [ repo ] } })
  end

  # Land the per-repo QA record a real `bin/release prepare` writes for each repo it
  # promoted + deployed. Naming ONE repo here is the mutation: it reproduces the
  # candidate that carried the hub and skipped turf.
  def qa_landed(release, *repos)
    Release::Conductor.record_qa_shas(release: release, shas: repos.to_h { |r| [ r, "#{r}-qa-sha" ] })
  end

  # Land the per-repo `release → main` record `bin/release ship` writes as each ff
  # lands on origin.
  def shipped_landed(release, *repos)
    Release::Conductor.record_shipped_shas(release: release, shas: repos.to_h { |r| [ r, "#{r}-prod-sha" ] })
  end

  # --- the task's release identity ---

  test "[unit] release_repos carries EVERY repo the task names, primary first" do
    task = two_repo_task

    assert_equal HUB, task.release_repo, "the primary is unchanged — parsed from pr_url"
    assert_equal [ HUB, TURF ], task.release_repos
  end

  test "[unit] release_repos surfaces a repo known ONLY from its recorded PR url" do
    task = Task.create!(title: "repo from pr only", stage: "reviewed",
                        metadata: { "devops" => { "repositories" => [ HUB ], "pr_url" => HUB_PR,
                                                  "pr_urls" => { TURF => TURF_PR } } })

    assert_includes task.release_repos, TURF, "a recorded PR is proof the repo is in the task"
  end

  test "[unit] release_pr_urls folds the singular pr_url in under the repo it names" do
    task = Task.create!(title: "folds primary pr url", stage: "reviewed",
                        metadata: { "devops" => { "repositories" => [ HUB, TURF ], "pr_url" => HUB_PR } })

    assert_equal({ HUB => HUB_PR }, task.release_pr_urls)
    assert_equal [ TURF ], task.repos_missing_pr_url, "turf's PR has nowhere to live yet — that is the bug"
  end

  test "[unit] the devops normalizer keeps pr_urls a MAP instead of stringifying it" do
    # Every writer funnels through here. The scalar branch would have written
    # '{"turf-monster"=>"https://…"}' and the list branch would have split it on
    # commas — either way the map would be unreadable and the refusal unclearable.
    normalized = Task.normalize_devops_metadata("pr_urls" => { TURF => TURF_PR })

    assert_equal({ "pr_urls" => { TURF => TURF_PR } }, normalized)
  end

  test "[unit] the normalizer keys a bare list of PR urls by the repo each names" do
    normalized = Task.normalize_devops_metadata("pr_urls" => [ HUB_PR, TURF_PR ])

    assert_equal({ "pr_urls" => { HUB => HUB_PR, TURF => TURF_PR } }, normalized)
  end

  test "[unit] the normalizer REFUSES a pr_urls entry that names no repo" do
    # A silently-dropped PR url is exactly the failure this key exists to close.
    error = assert_raises(ArgumentError) do
      Task.normalize_devops_metadata("pr_urls" => [ "https://example.com/not-a-pr" ])
    end
    assert_match(/names no repo/, error.message)
  end

  # --- the plan (necessary, but NOT the proof — see the header) ---

  test "[unit] repo_plan fans a two-repo member out into BOTH repos" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)

    plan = Release::Conductor.repo_plan(release)

    assert_equal [ HUB, TURF ].sort, plan.map { |g| g[:repo] }.sort
    plan.each do |group|
      assert_includes group[:members].map { |m| m[:slug] }, task.slug,
                      "the member must appear in every repo it names"
    end
  end

  test "[unit] a member's post_deploy_cmd rides ONLY its primary repo's group" do
    task = two_repo_task
    task.update!(metadata: task.metadata.deep_merge("devops" => { "post_deploy_cmd" => "rake hub:backfill" }))
    release = Release::Conductor.sweep!(task)

    plan = Release::Conductor.repo_plan(release).index_by { |g| g[:repo] }

    assert_equal "rake hub:backfill", plan[HUB][:members].first[:post_deploy_cmd]
    assert_nil plan[TURF][:members].first[:post_deploy_cmd],
               "a hub rake task must not be fired at turf's dyno just because the task names turf"
  end

  # --- THE EFFECT: `assembled` requires per-repo evidence ---

  test "[integration] a two-repo member whose second repo was never promoted does NOT reach assembled" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB) # the mutation: this candidate carried the hub and skipped turf

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "a member spanning a repo the candidate never QA'd must not be stamped assembled"
    assert_equal Task::MERGED_RELEASE, task.merged, "it stays swept, for the next self-healing run"
  end

  test "[integration] the same member DOES reach assembled once the missing repo lands" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB)
    Release::Conductor.qa_green!(release.reload)
    assert_equal "reviewed", task.reload.stage

    qa_landed(release.reload, TURF) # the second repo finally rides
    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage
  end

  test "[integration] a single-repo member on the same candidate still assembles" do
    # The guard must be precise: holding the neighbours would jam the release.
    two_repo = two_repo_task
    neighbour = single_repo_task
    release = Release::Conductor.sweep!(two_repo)
    Release::Conductor.sweep!(neighbour)
    qa_landed(release.reload, HUB)

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", neighbour.reload.stage
    assert_equal "reviewed", two_repo.reload.stage
  end

  # --- THE EFFECT: `shipped` requires per-repo evidence ---

  test "[integration] a two-repo member whose second repo never reached main does NOT reach shipped" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, HUB) # the mutation: only the hub's `main` moved
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "assembled", task.stage,
                 "a member spanning a repo whose main never moved must not be stamped shipped"
    refute_equal Task::MERGED_MAIN, task.merged,
                 "and it must never claim its code is on main"
  end

  test "[integration] the same member ships once its second repo's main lands" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    shipped_landed(release.reload, HUB)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, TURF)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "shipped", task.stage
    assert_equal Task::MERGED_MAIN, task.merged
  end

  test "[integration] a single-repo member ships alongside a held multi-repo one" do
    two_repo = two_repo_task
    neighbour = single_repo_task
    release = Release::Conductor.sweep!(two_repo)
    Release::Conductor.sweep!(neighbour)
    qa_landed(release.reload, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    shipped_landed(release.reload, HUB)

    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    assert_equal "shipped", neighbour.reload.stage
    assert_equal "assembled", two_repo.reload.stage
  end

  # --- the curation guard, checked over EVERY repo a member names ---
  #
  # The other half of the sweep-time refusal — a multi-repo member whose PR record
  # covers only SOME of its repos — lands with Release::SweepPlan's coverage rule
  # and `bin/release prepare`'s pre-promote screen. Until then such a member sweeps
  # and is caught one stage later, by the per-repo evidence guard above: it can ride
  # the candidate, but it cannot be STAMPED for the repo with no landed record.

  test "[unit] validate_members! passes a multi-repo member with a PR url per repo" do
    release = Release::Conductor.sweep!(two_repo_task)

    assert_nothing_raised { Release::Conductor.validate_members!(release.reload) }
  end

  test "[unit] validate_members! catches an unregistered SECOND repo" do
    task = Task.create!(title: "names an unknown repo", stage: "reviewed",
                        metadata: { "devops" => {
                          "repositories" => [ HUB, "not-a-registered-repo" ],
                          "pr_url" => HUB_PR,
                          "pr_urls" => { HUB => HUB_PR,
                                         "not-a-registered-repo" => "https://github.com/x/not-a-registered-repo/pull/1" }
                        } })
    release = Release::Conductor.sweep!(task)

    error = assert_raises(ArgumentError) { Release::Conductor.validate_members!(release.reload) }

    assert_match(/unknown repo/, error.message)
    assert_match(/not-a-registered-repo/, error.message)
  end

  # --- A GEM MEMBER: two different questions, two different sets ---
  #
  # Slice 1's review left this decision to this slice, so decide it explicitly.
  # #pr_bearing_repositories deliberately UNDER-measures a gem task: an engine task
  # names its consumers, but the work is ONE PR in the gem repo, so it is measured
  # against the gem alone and no PR is ever demanded of a consumer. That under-
  # measures a gem task that legitimately carries a consumer PR too (the breaking-
  # change forward-compat shape).
  #
  # KEEPING IT, because the two sets answer different questions and #release_repos
  # is the one that governs membership:
  #   * #pr_bearing_repositories = "which repos did the BUILDER owe a PR in" — the
  #     set slice 4's sweep-time refusal will measure. Widening it to the consumers
  #     would re-create the exact inversion it exists to prevent: every legitimate
  #     engine release would report both consumers "missing a PR", and once the
  #     refusal is wired that would BLOCK every engine release for the absence of
  #     work nobody is supposed to do.
  #   * #release_repos = "which repos does this task SHIP through" — a deliberate
  #     SUPERSET, built from the declared repositories regardless of PR coverage.
  #     A consumer can therefore never fall out of the plan because no PR was
  #     demanded of it, and it is still held to per-repo evidence.
  # So the residual risk is bounded and visible: a gem task missing a consumer
  # forward-compat PR is not refused at sweep time, but its consumer is still
  # promoted, still deployed and still evidence-guarded — it fails at QA rather
  # than shipping silently. These two tests pin exactly that.

  ENGINE = "studio-engine"
  ENGINE_PR = "https://github.com/McRitchie-Studio/studio-engine/pull/77"

  def gem_task(label = "engine")
    Task.create!(
      title: "bump #{label} for consumers",
      stage: "reviewed",
      metadata: { "devops" => {
        "shape" => "library",
        "repositories" => [ ENGINE, HUB, TURF ],
        "pr_url" => ENGINE_PR,
        "pr_urls" => { ENGINE => ENGINE_PR }
      } }
    )
  end

  test "[unit] a gem task PLANS its consumers even though it owes them no PR" do
    task = gem_task

    assert_equal [ ENGINE ], task.pr_bearing_repositories,
                 "the work is one PR in the gem repo — a consumer PR must never be demanded"
    assert_empty task.repos_missing_pr_url,
                 "a legitimate engine release must not report its consumers missing"
    assert_equal [ ENGINE, HUB, TURF ], task.release_repos,
                 "membership is a SUPERSET of PR coverage — the consumers still ship"
    assert_operator (task.release_repos & task.pr_bearing_repositories).size, :==,
                    task.pr_bearing_repositories.size,
                    "release_repos must contain every pr_bearing repo — the invariant slice 4 relies on"
  end

  test "[integration] a gem member whose CONSUMER never got QA does NOT reach assembled" do
    # The under-measured case, driven: no PR was ever demanded of turf, so nothing
    # refused this member at sweep time. Evidence is what still catches it.
    task = gem_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB) # the mutation: the gem published, the hub deployed, turf did not

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "turf carried no QA record — the member must be HELD, not stamped assembled"
  end

  test "[integration] the gem member assembles once every consumer lands, gem exempt" do
    task = gem_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF) # both consumers deployed; the GEM is published, never deployed

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage,
                 "a gem repo carries no QA sha by design — demanding one would hold every gem forever"
  end
end
