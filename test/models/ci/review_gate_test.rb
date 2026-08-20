# frozen_string_literal: true

require "test_helper"

module Ci
  # [unit] Ci::ReviewGate — the server-side, DB-native "is this task's PR CI concluded
  # GREEN?" gate that POST /api/v1/tasks/claim_next_review pops on. It resolves the
  # task's PR head_sha from the newest ingested `CI` GithubWorkflowRun on its branch,
  # joins the run(s) for that head_sha, and folds them through CiStatus's verdict
  # semantics — never a live `gh` call.
  class ReviewGateTest < ActiveSupport::TestCase
    REPO = "McRitchie-Studio/mcritchie-studio"

    setup { GithubWorkflowRun.delete_all }

    test "[unit] green when the CI run for the task's head_sha concluded success" do
      task = submitted(branch: "feat/green", pr: 1)
      seed_run(branch: "feat/green", sha: "sha-green", status: "completed", conclusion: "success")

      assert Ci::ReviewGate.green?(task)
      assert_equal :green, Ci::ReviewGate.verdict(task)[:state]
      assert_equal "sha-green", Ci::ReviewGate.verdict(task)[:sha], "the verdict carries the resolved head_sha"
    end

    test "[unit] red when the CI run concluded failure — never green" do
      task = submitted(branch: "feat/red", pr: 2)
      seed_run(branch: "feat/red", sha: "sha-red", status: "completed", conclusion: "failure")

      refute Ci::ReviewGate.green?(task)
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] pending while the CI run is still in flight — not green" do
      task = submitted(branch: "feat/pending", pr: 3)
      seed_run(branch: "feat/pending", sha: "sha-pending", status: "in_progress", conclusion: nil)

      refute Ci::ReviewGate.green?(task)
      assert_equal :pending, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] none when no CI run has been ingested for the task's branch" do
      task = submitted(branch: "feat/ci-less", pr: 4) # no seed_run

      refute Ci::ReviewGate.green?(task)
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] no_pr when the task carries no PR yet" do
      task = Task.create!(title: "no pr gate", stage: "submitted",
                          metadata: { "devops" => { "branch" => "feat/no-pr", "repositories" => ["mcritchie-studio"] } })

      refute Ci::ReviewGate.green?(task)
      assert_equal :no_pr, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a green run on a DIFFERENT branch never greens this task (the head_sha join is scoped)" do
      task = submitted(branch: "feat/mine", pr: 5)
      seed_run(branch: "feat/someone-else", sha: "sha-theirs", status: "completed", conclusion: "success")

      refute Ci::ReviewGate.green?(task), "CI for another branch's head must not satisfy this task's gate"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a re-run supersedes a stale failed run for the same head_sha" do
      task = submitted(branch: "feat/rerun", pr: 6)
      # Attempt 1 failed; attempt 2 (newer run_id + run_started_at) on the SAME sha is green.
      seed_run(branch: "feat/rerun", sha: "sha-rerun", status: "completed", conclusion: "failure",
               run_id: 100, started: 2.minutes.ago)
      seed_run(branch: "feat/rerun", sha: "sha-rerun", status: "completed", conclusion: "success",
               run_id: 200, started: 1.minute.ago)

      assert Ci::ReviewGate.green?(task), "the freshest run for the head_sha is the live verdict"
    end

    test "[unit] the injected token seam short-circuits the DB read" do
      task = submitted(branch: "feat/inject", pr: 7) # no runs seeded at all

      assert Ci::ReviewGate.green?(task, injected: "green")
      refute Ci::ReviewGate.green?(task, injected: "red")
      assert_equal :pending, Ci::ReviewGate.verdict(task, injected: "pending")[:state]
    end

    # ── Gem repos name their CI workflow differently ──────────────────────────
    #
    # A GEM repo does not run a workflow called "CI". studio-engine runs "Engine CI"
    # (its own suite) and "Consumer CI" (the downstream apps'). The gate resolved the
    # literal "CI" for every repo, so a gem PR's runs never matched, the sha came back
    # blank, and the verdict was :none — NOT green, forever. claim_next_review then
    # skipped it on every wave, which made every studio-engine PR permanently
    # unclaimable by pr-review and forced a manual merge outside the gate.

    test "[unit] green when a GEM repo's own suite workflow concluded success" do
      task = submitted(branch: "feat/gem-green", pr: 8, repo: "studio-engine")
      seed_run(branch: "feat/gem-green", sha: "sha-gem-green", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/studio-engine", workflow: "Engine CI")

      assert Ci::ReviewGate.green?(task),
             "a gem PR whose own suite CI concluded success must be claimable — it was skipped as :none"
      assert_equal :green, Ci::ReviewGate.verdict(task)[:state]
      assert_equal "sha-gem-green", Ci::ReviewGate.verdict(task)[:sha]
    end

    test "[unit] a GEM repo's failing suite is red, not none" do
      task = submitted(branch: "feat/gem-red", pr: 9, repo: "studio-engine")
      seed_run(branch: "feat/gem-red", sha: "sha-gem-red", status: "completed", conclusion: "failure",
               repo: "McRitchie-Studio/studio-engine", workflow: "Engine CI")

      refute Ci::ReviewGate.green?(task)
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state],
                   "a gem's failing suite must READ as red — :none would hide a real failure behind 'no CI'"
    end

    # The name filter is load-bearing in BOTH directions. studio-engine's downstream
    # "Consumer CI" runs on the same commits but is not the gem's own verdict, so it
    # must never satisfy the gate on its own.
    test "[unit] a gem's sibling workflow does not satisfy the gate" do
      task = submitted(branch: "feat/gem-sibling", pr: 10, repo: "studio-engine")
      seed_run(branch: "feat/gem-sibling", sha: "sha-sibling", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/studio-engine", workflow: "Consumer CI")

      refute Ci::ReviewGate.green?(task),
             "Consumer CI is the downstream apps' suite, not the gem's own verdict"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    # ── Fail closed when the workflow cannot be resolved ──────────────────────
    #
    # solana-studio is a REGISTERED gem that ships no suite workflow, so
    # ci_workflow_for returns nil. An earlier version dropped the workflow filter in
    # that case, which meant "any run on the branch greens this PR". Two ways that
    # authorised a merge it should not have — both are now :none.

    test "[unit] an unresolved workflow reads :none, never green off an unrelated run" do
      task = submitted(branch: "feat/no-suite", pr: 12, repo: "solana-studio")
      seed_run(branch: "feat/no-suite", sha: "sha-unrelated", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/solana-studio", workflow: "Publish Gem")

      assert_nil GithubWorkflowRun.ci_workflow_for("solana-studio"),
                 "precondition: solana-studio declares no suite workflow"
      refute Ci::ReviewGate.green?(task),
             "a repo with no declared suite must never green off an unrelated workflow"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a later unrelated PASS cannot mask an earlier real FAILURE" do
      task = submitted(branch: "feat/masked", pr: 13, repo: "solana-studio")
      # The real suite failed; a lint job on the SAME sha passed afterwards.
      seed_run(branch: "feat/masked", sha: "sha-masked", status: "completed", conclusion: "failure",
               repo: "McRitchie-Studio/solana-studio", workflow: "CI", run_id: 300, started: 2.minutes.ago)
      seed_run(branch: "feat/masked", sha: "sha-masked", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/solana-studio", workflow: "Lint", run_id: 400, started: 1.minute.ago)

      refute Ci::ReviewGate.green?(task),
             "the newest unrelated PASS must not mask the real FAILURE — this greened a red PR"
      assert_equal :none, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] an APP repo is still resolved by the plain CI workflow" do
      task = submitted(branch: "feat/app-still-works", pr: 11)
      seed_run(branch: "feat/app-still-works", sha: "sha-app", status: "completed", conclusion: "success")

      assert Ci::ReviewGate.green?(task), "the app path must be unchanged by gem awareness"
    end

    # [integration] The end-to-end recovery: a flake fails CI, the operator re-runs
    # it, and the gate must go green so claim-next-review can pop the task. This is
    # driven through the real webhook ingest — a re-run reuses the run_id, so before
    # the ingest fix the row stayed `failure` and the PR was green on GitHub yet
    # permanently unclaimable on the board.
    test "[integration] a re-run's green delivery flips the gate from red to green" do
      task = submitted(branch: "feat/rerun-recovery", pr: 12)
      run_id = 31_276_835_993
      deliver = lambda do |status, conclusion, attempt|
        GithubWorkflowRunIngestJob.perform_now("workflow_run", {
          "workflow_run" => {
            "id" => run_id, "name" => "CI", "status" => status, "conclusion" => conclusion,
            "run_attempt" => attempt, "head_sha" => "sha-rerun",
            "head_branch" => "feat/rerun-recovery", "run_started_at" => "2026-08-08T20:00:00Z"
          },
          "repository" => { "full_name" => REPO }
        })
      end

      deliver.call("completed", "failure", 1)
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state]
      refute Ci::ReviewGate.green?(task)

      deliver.call("in_progress", nil, 2)
      deliver.call("completed", "success", 2)

      assert_equal :green, Ci::ReviewGate.verdict(task)[:state],
                   "the board must see what GitHub sees after a re-run"
      assert Ci::ReviewGate.green?(task)
      assert_equal 1, GithubWorkflowRun.where(run_id: run_id).count,
                   "a re-run reuses the run_id — it must not fork a second row"
    end

    # ── EVERY LANE ON THE TREE COUNTS, not just the suite one ─────────────────
    #
    # THE INCIDENT (studio-engine PR #111, 2026-08-13). GitHub queued TWO workflow
    # runs on head 2d50675 at 21:02:07Z: `Engine CI`, which concluded success at
    # 21:03:47Z, and `Consumer CI`, which concluded success at 21:09:36Z. The armed
    # merge fired at 21:06:02Z — in the window between them, while Consumer CI was
    # still `in_progress`.
    #
    # It fired because the fold read ONE row: the newest run whose workflow_name
    # equalled the repo's resolved suite. Consumer CI was not EXCLUDED as a failure
    # or counted as pending — it was dropped from the payload before CiStatus ever
    # saw it, so the fold was handed a single completed success and correctly called
    # that green. The verdict was green about a QUESTION IT HAD NOT ASKED.
    #
    # `count: 1` was always the tell, and it is asserted below: a gate that reads one
    # lane of six cannot honour "red, pending, cancelled and absent all do nothing".
    #
    # THE FIX IS QUERY SCOPE, NOT THE FOLD. CiStatus.fold is positively framed
    # (:green iff EVERY run affirmatively passed/skipped) and check_run_bucket
    # already fail-safes a non-`completed` status to pending — both were correct and
    # are unchanged. Only the SET handed to them was wrong.
    #
    # SHA RESOLUTION STAYS SCOPED to the suite workflow (latest_ci_sha), which is why
    # "a gem's sibling workflow does not satisfy the gate" above still reads :none:
    # Consumer CI alone resolves no tree to have an opinion about. The widening is
    # strictly about which runs ON AN ALREADY-RESOLVED TREE get a vote.

    ENGINE = "McRitchie-Studio/studio-engine"
    INCIDENT_SHA = "2d5067552c7401babda9d0777d398236194bd2b4"

    # The arrangement the incident actually had, minus the one thing under test.
    def seed_incident(branch:, sibling_status:, sibling_conclusion:, sha: INCIDENT_SHA)
      seed_run(branch: branch, sha: sha, status: "completed", conclusion: "success",
               repo: ENGINE, workflow: "Engine CI", run_id: 501, started: 3.minutes.ago)
      seed_run(branch: branch, sha: sha, status: sibling_status, conclusion: sibling_conclusion,
               repo: ENGINE, workflow: "Consumer CI", run_id: 502, started: 3.minutes.ago)
    end

    # THE GUARD AGAINST A VACUOUS TEST. If the lane under test were the repo's own
    # suite workflow, every case below would pass on the UNFIXED code too — the old
    # single-row read caught a pending SUITE perfectly well. The whole defect is that
    # a lane the suite filter drops never reaches the fold, so each test asserts the
    # lane it seeds is genuinely one the old query would have discarded.
    def assert_lane_was_excluded_before(lane, repo: "studio-engine")
      suite = GithubWorkflowRun.ci_workflow_for(repo)
      assert_not_equal suite, lane,
                       "precondition: #{lane} must NOT be #{repo}'s resolved suite (#{suite}), or this " \
                       "test also passes against the bug it exists to catch"
    end

    test "[unit] a sibling lane still IN PROGRESS on the reviewed tree is pending, never green" do
      task = submitted(branch: "feat/slow-consumer", pr: 111, repo: "studio-engine")
      seed_incident(branch: "feat/slow-consumer", sibling_status: "in_progress", sibling_conclusion: nil)
      assert_lane_was_excluded_before("Consumer CI")

      verdict = Ci::ReviewGate.verdict(task)
      refute Ci::ReviewGate.green?(task),
             "the armed merge for PR #111 fired here: one lane green, one still running"
      assert_equal :pending, verdict[:state]
      assert_includes Array(verdict[:pending]), "Consumer CI",
                      "the running lane must be NAMED as pending, not silently dropped"
    end

    test "[unit] a sibling lane still QUEUED is pending, never green" do
      task = submitted(branch: "feat/queued-consumer", pr: 112, repo: "studio-engine")
      seed_incident(branch: "feat/queued-consumer", sibling_status: "queued", sibling_conclusion: nil)
      assert_lane_was_excluded_before("Consumer CI")

      refute Ci::ReviewGate.green?(task), "a lane GitHub has queued but not started is not a pass"
      assert_equal :pending, Ci::ReviewGate.verdict(task)[:state]
    end

    test "[unit] a sibling lane that FAILED is red, never green" do
      task = submitted(branch: "feat/red-consumer", pr: 113, repo: "studio-engine")
      seed_incident(branch: "feat/red-consumer", sibling_status: "completed", sibling_conclusion: "failure")
      assert_lane_was_excluded_before("Consumer CI")

      verdict = Ci::ReviewGate.verdict(task)
      refute Ci::ReviewGate.green?(task),
             "a gem's downstream consumer suite going red is exactly what it exists to catch"
      assert_equal :red, verdict[:state]
      assert_includes Array(verdict[:failing]), "Consumer CI"
    end

    test "[unit] a sibling lane that was CANCELLED is red, never green" do
      task = submitted(branch: "feat/cancelled-consumer", pr: 114, repo: "studio-engine")
      seed_incident(branch: "feat/cancelled-consumer", sibling_status: "completed", sibling_conclusion: "cancelled")
      assert_lane_was_excluded_before("Consumer CI")

      refute Ci::ReviewGate.green?(task), "a cancelled lane verified nothing"
      assert_equal :red, Ci::ReviewGate.verdict(task)[:state]
    end

    # THE POSITIVE CONTROL. A guard that blocks everything is not a guard, and a
    # merge gate that can never open would strand the autopilot it serves. `count`
    # is asserted because it is the DIRECT reading of "all lanes voted": the same
    # arrangement returned count: 1 before, which is what let one green lane speak
    # for six.
    test "[unit] green once EVERY lane on the tree has concluded success" do
      task = submitted(branch: "feat/all-green", pr: 115, repo: "studio-engine")
      seed_incident(branch: "feat/all-green", sibling_status: "completed", sibling_conclusion: "success")

      verdict = Ci::ReviewGate.verdict(task)
      assert Ci::ReviewGate.green?(task), "a fully concluded green tree must still merge"
      assert_equal :green, verdict[:state]
      assert_equal 2, verdict[:count],
                   "both lanes must have voted — count: 1 is the signature of the single-row read"
      assert_equal INCIDENT_SHA, verdict[:sha]
    end

    # The widening must not undo the re-run rule: a SUPERSEDED run of the same
    # workflow still drops, so an old failed attempt cannot outvote its own re-run.
    # Newest-per-workflow, not newest-overall and not all-rows.
    test "[unit] a superseded run of the same workflow still drops when other lanes are folded" do
      task = submitted(branch: "feat/rerun-plus-sibling", pr: 116, repo: "studio-engine")
      seed_run(branch: "feat/rerun-plus-sibling", sha: INCIDENT_SHA, status: "completed", conclusion: "failure",
               repo: ENGINE, workflow: "Engine CI", run_id: 601, started: 5.minutes.ago)
      seed_run(branch: "feat/rerun-plus-sibling", sha: INCIDENT_SHA, status: "completed", conclusion: "success",
               repo: ENGINE, workflow: "Engine CI", run_id: 602, started: 1.minute.ago)
      seed_run(branch: "feat/rerun-plus-sibling", sha: INCIDENT_SHA, status: "completed", conclusion: "success",
               repo: ENGINE, workflow: "Consumer CI", run_id: 603, started: 2.minutes.ago)

      assert Ci::ReviewGate.green?(task),
             "the re-run is the Engine CI verdict; folding its stale attempt too would pin the gate red"
      assert_equal 2, Ci::ReviewGate.verdict(task)[:count], "one vote per workflow, the newest attempt"
    end

    # An APP repo has the same shape — the defect was never gem-specific. A second
    # workflow on an app's PR head (a scheduled scan, a deploy preview) was dropped
    # by the identical filter.
    test "[unit] an APP repo's sibling workflow is folded too" do
      task = submitted(branch: "feat/app-sibling", pr: 117)
      seed_run(branch: "feat/app-sibling", sha: "sha-app-sibling", status: "completed", conclusion: "success",
               workflow: "CI", run_id: 701)
      seed_run(branch: "feat/app-sibling", sha: "sha-app-sibling", status: "in_progress", conclusion: nil,
               workflow: "CodeQL", run_id: 702)
      assert_lane_was_excluded_before("CodeQL", repo: "mcritchie-studio")

      refute Ci::ReviewGate.green?(task), "an app's second lane still running is not a green tree"
      assert_equal :pending, Ci::ReviewGate.verdict(task)[:state]
    end

    # ── EVERY REPO THE TASK HAS A PR IN GETS A VOTE ───────────────────────────
    #
    # THE DEFECT (found 2026-08-19, landing the CERT half of this family):
    # `repo_for` was `Array(task.devops_repositories).first` — repo #1, silently. So
    # a task landing PRs in TWO repos was popped for review, and AUTO-MERGED by
    # Review::PendingActionExecutor, on repo #1's CI alone. A red or still-running
    # repo #2 was not outvoted or reported; it was never asked.
    #
    # THE GUARD AGAINST A VACUOUS TEST: every case below turns on the SECOND repo,
    # and asserts the FIRST repo is green. A test that checks "a single-repo task
    # still claims" passes identically on the broken code — the defect only exists
    # from the second repo up, which is exactly where a passing test proves nothing
    # unless repo #1 is green while repo #2 is not.

    TURF = "McRitchie-Studio/turf-monster"
    ENGINE_PR = "https://github.com/McRitchie-Studio/studio-engine/pull/55"

    test "[unit] a two-repo task whose SECOND repo is red is not green" do
      task = two_repo(branch: "feat/two-red")
      seed_run(branch: "feat/two-red", sha: "sha-hub", status: "completed", conclusion: "success")
      seed_run(branch: "feat/two-red", sha: "sha-turf", status: "completed", conclusion: "failure", repo: TURF)

      verdict = Ci::ReviewGate.verdict(task)
      assert_equal :green, verdict[:repos]["mcritchie-studio"][:state],
                   "precondition: repo #1 IS green — the single-repo read stopped here and called the task green"
      refute Ci::ReviewGate.green?(task),
             "a task is ONE reviewed change: a red second repo must make the whole task un-green"
      assert_equal :red, verdict[:state]
      assert_equal "turf-monster", verdict[:repo], "the verdict must NAME the repo that stopped it"
      assert_equal %w[mcritchie-studio turf-monster], verdict[:repos].keys, "both repos must have voted"
    end

    test "[unit] a two-repo task whose SECOND repo is still running is pending, never green" do
      task = two_repo(branch: "feat/two-pending")
      seed_run(branch: "feat/two-pending", sha: "sha-hub", status: "completed", conclusion: "success")
      seed_run(branch: "feat/two-pending", sha: "sha-turf", status: "in_progress", conclusion: nil, repo: TURF)

      verdict = Ci::ReviewGate.verdict(task)
      refute Ci::ReviewGate.green?(task), "a second repo still building is not a green task"
      assert_equal :pending, verdict[:state]
      assert_equal "turf-monster", verdict[:repo]
    end

    # A repo with NO ingested run is the wiring gap, and it must read the same as any
    # other not-green: absence is never a pass.
    test "[unit] a two-repo task whose SECOND repo has no CI at all reads :none" do
      task = two_repo(branch: "feat/two-blind")
      seed_run(branch: "feat/two-blind", sha: "sha-hub", status: "completed", conclusion: "success")

      verdict = Ci::ReviewGate.verdict(task)
      refute Ci::ReviewGate.green?(task), "a repo the board holds no CI for must never pass on repo #1's green"
      assert_equal :none, verdict[:state]
      assert_equal "turf-monster", verdict[:repo]
    end

    # A red outranks a pending ACROSS repos, exactly as it does within one — the
    # actionable state is the one worth reporting.
    test "[unit] a red repo outranks a pending one in the fold" do
      task = two_repo(branch: "feat/two-mixed")
      seed_run(branch: "feat/two-mixed", sha: "sha-hub", status: "in_progress", conclusion: nil)
      seed_run(branch: "feat/two-mixed", sha: "sha-turf", status: "completed", conclusion: "failure", repo: TURF)

      verdict = Ci::ReviewGate.verdict(task)
      assert_equal :red, verdict[:state], "a red anywhere is the verdict, not the first non-green in list order"
      assert_equal "turf-monster", verdict[:repo]
    end

    # THE POSITIVE CONTROL. A gate that blocks every multi-repo task is not a gate —
    # it would strand the release conductor's canonical shape.
    test "[unit] a two-repo task is green once BOTH repos are green" do
      task = two_repo(branch: "feat/two-green")
      seed_run(branch: "feat/two-green", sha: "sha-hub", status: "completed", conclusion: "success")
      seed_run(branch: "feat/two-green", sha: "sha-turf", status: "completed", conclusion: "success", repo: TURF)

      verdict = Ci::ReviewGate.verdict(task)
      assert Ci::ReviewGate.green?(task), "both repos concluded success — this task must still be claimable"
      assert_equal :green, verdict[:state]
      assert_equal "sha-hub", verdict[:sha], "the folded sha stays the PRIMARY PR's — the pin the merge compares"
      assert_equal 2, verdict[:count], "the lanes that voted, summed across repos"
      assert_equal "sha-turf", verdict[:repos]["turf-monster"][:sha], "each repo keeps its own resolved head"
    end

    # ONE REPO, ONE READ — asked directly. This is the merge executor's head-sha pin:
    # an armed merge names one PR in one repo, so the sha it compares must come from
    # THAT repo's runs and not the fold's primary.
    test "[unit] verdict(repo:) answers about that repo alone" do
      task = two_repo(branch: "feat/two-pin")
      seed_run(branch: "feat/two-pin", sha: "sha-hub", status: "completed", conclusion: "success")
      seed_run(branch: "feat/two-pin", sha: "sha-turf", status: "completed", conclusion: "failure", repo: TURF)

      assert_equal :red, Ci::ReviewGate.verdict(task, repo: "turf-monster")[:state]
      assert_equal "sha-turf", Ci::ReviewGate.verdict(task, repo: "turf-monster")[:sha]
      assert_equal :green, Ci::ReviewGate.verdict(task, repo: "mcritchie-studio")[:state]
      assert_equal "sha-hub", Ci::ReviewGate.verdict(task, repo: "mcritchie-studio")[:sha]
    end

    # ── WHICH REPOS OWE A VERDICT: the PR register, not the declared list ──────

    # THE GEM-RELEASE PATH, and the case that refuted forbidding multi-repo tasks:
    # a gem task NAMES its consumer repos so the pipeline can reason that the gem
    # alone owes the PR. Those consumers have no branch and no runs, so demanding a
    # CI verdict for them would read :none forever and strand every engine release.
    test "[unit] a repo the task NAMES but has no PR in owes no verdict" do
      task = Task.create!(
        title: "gem release #{SecureRandom.hex(2)}", stage: "submitted",
        metadata: { "devops" => {
          "branch" => "feat/gem-consumers",
          "repositories" => %w[mcritchie-studio turf-monster],
          "pr_url" => ENGINE_PR
        } }
      )
      seed_run(branch: "feat/gem-consumers", sha: "sha-engine", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/studio-engine", workflow: "Engine CI")

      assert_equal ["studio-engine"], Ci::ReviewGate.repos_for(task),
                   "the PR register decides, not the declared list — the consumers owe no PR and no CI"
      assert Ci::ReviewGate.green?(task),
             "a gem release whose own suite is green must stay claimable; gating its PR-less consumers " \
             "would refuse work nobody is supposed to do"
    end

    # The primary repo comes from the PR URL, which is ALSO a fix: this shape read
    # `repositories.first` and looked for the HUB's runs on a branch that only exists
    # in the gem — :none, and permanently unclaimable.
    test "[unit] the repo under review is the PR url's, not repositories.first" do
      task = Task.create!(
        title: "gem mismatch #{SecureRandom.hex(2)}", stage: "submitted",
        metadata: { "devops" => {
          "branch" => "feat/gem-mismatch",
          "repositories" => ["mcritchie-studio"],
          "pr_url" => ENGINE_PR
        } }
      )
      seed_run(branch: "feat/gem-mismatch", sha: "sha-engine-2", status: "completed", conclusion: "success",
               repo: "McRitchie-Studio/studio-engine", workflow: "Engine CI")

      assert_equal ["studio-engine"], Ci::ReviewGate.repos_for(task)
      assert Ci::ReviewGate.green?(task), "the gate must read the repo the PR is actually in"
    end

    # The other direction, and why this reads wider than the cert gate's
    # `declared & pr_bearing` intersection: `bin/task update --pr-url-for` writes the
    # register WITHOUT touching `repositories`, so a PR-bearing repo the task never
    # named is one command away. Ungated, it is the silent pass this gate closes.
    test "[unit] a repo with a recorded PR is gated even when the task never named it" do
      task = two_repo(branch: "feat/undeclared", declare_second: false)
      seed_run(branch: "feat/undeclared", sha: "sha-hub", status: "completed", conclusion: "success")
      seed_run(branch: "feat/undeclared", sha: "sha-turf", status: "completed", conclusion: "failure", repo: TURF)

      assert_equal ["mcritchie-studio"], task.devops_repositories, "precondition: turf is NOT declared"
      assert_equal %w[mcritchie-studio turf-monster], Ci::ReviewGate.repos_for(task)
      refute Ci::ReviewGate.green?(task), "a recorded PR is code landing under this task — it owes a verdict"
    end

    test "[unit] a task with no PR owes no verdict at all" do
      task = Task.create!(title: "no pr repos #{SecureRandom.hex(2)}", stage: "submitted",
                          metadata: { "devops" => { "branch" => "feat/none",
                                                    "repositories" => %w[mcritchie-studio turf-monster] } })

      assert_empty Ci::ReviewGate.repos_for(task)
      assert_equal :no_pr, Ci::ReviewGate.verdict(task)[:state]
    end

    private

    # A task landing PRs in TWO repos: the hub (the primary `pr_url`) and turf (the
    # per-repo `pr_urls` register). `declare_second: false` models the register entry
    # written by `--pr-url-for` without a matching `repositories` edit.
    def two_repo(branch:, declare_second: true, pr: 20)
      repositories = declare_second ? %w[mcritchie-studio turf-monster] : ["mcritchie-studio"]
      Task.create!(
        title: "multi gate #{SecureRandom.hex(2)}",
        stage: "submitted",
        metadata: { "devops" => {
          "branch" => branch,
          "repositories" => repositories,
          "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/#{pr}",
          "pr_urls" => { "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/#{pr + 1}" }
        } }
      )
    end

    def submitted(branch:, pr:, repo: "mcritchie-studio")
      Task.create!(
        title: "gate demo #{SecureRandom.hex(2)}",
        stage: "submitted",
        metadata: { "devops" => {
          "branch" => branch,
          "repositories" => [repo],
          "pr_url" => "https://github.com/McRitchie-Studio/#{repo}/pull/#{pr}"
        } }
      )
    end

    def seed_run(branch:, sha:, status:, conclusion:, run_id: nil, started: Time.current,
                 repo: REPO, workflow: "CI")
      GithubWorkflowRun.create!(
        repo: repo, workflow_name: workflow,
        run_id: run_id || SecureRandom.random_number(10**12),
        status: status, conclusion: conclusion,
        head_branch: branch, head_sha: sha, run_started_at: started
      )
    end
  end
end
