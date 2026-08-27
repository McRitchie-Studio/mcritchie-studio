# frozen_string_literal: true

require "test_helper"

module Ci
  # The rung state machine, and above all the two states that exist to stop a
  # stale or absent verdict rendering as green.
  class LadderRungTest < ActiveSupport::TestCase
    # --- resolve_state: the one interpretation this class adds ---------------

    test "no ingested verdict reads not_built, never green" do
      assert_equal :not_built, Ci::LadderRung.resolve_state(:none)
    end

    test "every real verdict passes through untouched" do
      %i[green red pending conflicted].each do |raw|
        assert_equal raw, Ci::LadderRung.resolve_state(raw),
                     "#{raw} is CI's verdict and must not be reinterpreted"
      end
    end

    # --- the regression this class was changed for --------------------------

    # PROVEN IN PRODUCTION 2026-08-20: turf-monster `release` read green@e1217b6 from
    # BranchGate while the badge rendered stale, because a task was stamped 47 SECONDS
    # after the run started. The old rule compared two clocks that measure different
    # events — code lands, CI starts, THEN the sweep writes the stamp — so the stamp
    # is always later and a green rung went faded by construction.
    test "a green verdict stays green however late the parked stamp lands" do
      rung = Ci::LadderRung.new(repo: "turf-monster", branch: "release", state: :green,
                                sha: "e1217b6", verdict_at: Time.utc(2026, 8, 20, 18, 38, 0),
                                parked_count: 1)

      assert_equal :green, rung.state
      refute rung.needs_attention?, "a green rung asks for no attention"
    end

    # The same false positive on `main`, where every ship stamps its members minutes
    # after main's own run — it made all four cards read stale after every release.
    test "a green main rung stays green after a ship stamps its members" do
      assert_equal :green, Ci::LadderRung.resolve_state(:green)
    end

    test "the stale state no longer exists anywhere in the rank table" do
      refute_includes Ci::LadderRung::STATE_RANK.keys, :stale
      refute_includes Ci::LadderRung::ATTENTION_STATES, :stale
    end

    # --- ranking / display ---------------------------------------------------

    test "attention states are exactly red and conflicted" do
      assert_equal %i[red conflicted].sort, Ci::LadderRung::ATTENTION_STATES.sort

      %i[red conflicted].each do |s|
        assert rung(state: s).needs_attention?, "#{s} must ask for attention"
      end
      %i[green pending not_built].each do |s|
        refute rung(state: s).needs_attention?, "#{s} must not ask for attention"
      end
    end

    test "worse states sort ahead of better ones" do
      states = %i[green not_built pending conflicted red]
      ordered = states.map { |s| rung(state: s) }.sort_by(&:sort_key).map(&:state)

      assert_equal %i[red conflicted pending not_built green], ordered
    end

    test "at the same state a rung with parked work sorts ahead of an idle one" do
      busy = rung(state: :green, parked_count: 2)
      idle = rung(state: :green, parked_count: 0)

      assert_equal 0, busy.sort_key.last, "parked work must carry the leading tiebreak"
      assert_equal(-1, busy.sort_key <=> idle.sort_key, "busy must sort ahead of idle")
    end

    test "short_sha truncates and tolerates a blank sha" do
      assert_equal "abc1234", rung(sha: "abc1234def5678").short_sha
      assert_nil rung(sha: nil).short_sha
    end

    test "not_built renders a readable label" do
      assert_equal "not built", rung(state: :not_built).label
      assert_equal "green", rung(state: :green).label
    end



    # --- lanes: what the meter counts, and what it leaves out ----------------

    # THE REGRESSION THIS TASK EXISTS FOR. studio-engine accepted@135e4e6 rendered a
    # RED badge over a GREEN 3/3 meter, because the badge folds every workflow on the
    # sha while the meter folds only the declared suite — and CiCheckJob never ingests
    # Consumer CI at all. Forcing them to agree is wrong (ci_check_job.rb:53-58: the
    # scope stops a failing consumer dragging the gem's own track red), so the card
    # NAMES the lanes the meter leaves out instead.
    test "lanes reports every workflow on the sha, from the badge's own source" do
      GithubWorkflowRun.delete_all
      sha = "135e4e6bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      run = lambda do |workflow, status, conclusion, id|
        GithubWorkflowRun.create!(repo: "McRitchie-Studio/studio-engine", head_sha: sha,
                                  head_branch: "accepted", run_id: id, workflow_name: workflow,
                                  status: status, conclusion: conclusion,
                                  run_started_at: 10.minutes.ago, html_url: "https://x/#{id}")
      end
      run.call("Engine CI", "completed", "success", 7_100_001)
      run.call("Consumer CI", "completed", "failure", 7_100_002)

      rung = Ci::LadderRung.new(repo: "studio-engine", branch: "accepted", state: :red, sha: sha)

      assert_equal 2, rung.lanes.size, "both lanes on the sha are reported"
      assert_equal %w[Consumer\ CI Engine\ CI].sort, rung.lanes.map { |l| l[:name] }.sort
      assert_equal :red, rung.lanes.first[:state], "a failing lane sorts to the front"
      assert_equal "Consumer CI", rung.lanes.first[:name]
    end

    # THE LEGEND is every lane the meter counts — it used to be every lane it COULD
    # NOT count, which is the change this row records.
    test "[unit] legend_lanes lists every lane the meter folds, red first" do
      GithubWorkflowRun.delete_all
      sha = "135e4e6ccccccccccccccccccccccccccccccccc"
      [["Engine CI", "success", 7_200_001], ["Consumer CI", "failure", 7_200_002]].each do |wf, concl, id|
        GithubWorkflowRun.create!(repo: "McRitchie-Studio/studio-engine", head_sha: sha,
                                  head_branch: "accepted", run_id: id, workflow_name: wf,
                                  status: "completed", conclusion: concl,
                                  run_started_at: 5.minutes.ago, html_url: "https://x/#{id}")
      end
      rung = Ci::LadderRung.new(repo: "studio-engine", branch: "accepted", state: :red, sha: sha)

      assert_equal ["Consumer CI", "Engine CI"], rung.legend_lanes.map { |l| l[:name] },
                   "both lanes are in the meter, so both are in its legend"
      assert_equal :red, rung.legend_lanes.first[:state]
      assert_equal "Engine CI", rung.primary_lane, "the gem's own suite still carries its verdict"
    end

    # The label points at the NEWS. A red lane outranks a running one, and neither
    # outranks the other when several are out — then it counts.
    test "[unit] meter_lane_label names the lane that is the news" do
      red     = { name: "Consumer CI", state: :red, url: nil }
      pending = { name: "Consumer CI", state: :pending, url: nil }
      green   = { name: "Engine CI", state: :green, url: nil }
      rung    = Ci::LadderRung.new(repo: "studio-engine", branch: "release", state: :pending)

      assert_equal "Engine CI", rung.meter_lane_label([green]),
                   "one lane: name it, exactly as every app card always has"
      assert_equal "Consumer CI", rung.meter_lane_label([green, pending]),
                   "the still-running lane is the current step the operator is waiting on"
      assert_equal "Consumer CI", rung.meter_lane_label([green, red]),
                   "a failure outranks a pass"
      assert_equal "2 suites", rung.meter_lane_label([green, { name: "Extra CI", state: :green, url: nil }]),
                   "naming one of two settled lanes would imply the other is not in the bar"
      assert_nil rung.meter_lane_label([]), "no lanes, no label"
    end

    # An app runs one lane, so its card gains no extra line to read.
    test "[unit] a single lane repo shows no legend" do
      GithubWorkflowRun.delete_all
      sha = "abc1234ddddddddddddddddddddddddddddddddd"
      GithubWorkflowRun.create!(repo: "McRitchie-Studio/turf-monster", head_sha: sha,
                                head_branch: "release", run_id: 7_300_001, workflow_name: "CI",
                                status: "completed", conclusion: "success",
                                run_started_at: 5.minutes.ago, html_url: "https://x/1")
      rung = Ci::LadderRung.new(repo: "turf-monster", branch: "release", state: :green, sha: sha)

      assert_equal "CI", rung.primary_lane
      assert_empty rung.legend_lanes, "one lane needs no key — the meter label already names it"
      assert_equal "CI", rung.meter_lane_label
    end

    # THE ANTI-CONTRADICTION TEST — the whole reason this change exists.
    #
    # The pill (#state, via .fold) has always counted every suite lane; the meter
    # (#progress) counted one. On the only two-lane repo that produced a card which
    # disagreed with itself: a green 3/3 "Engine CI" meter beside an AMBER `release`
    # pill, six minutes' worth, while Consumer CI ran the consumer suites. Assert the
    # two fold the SAME set, not merely that today's numbers happen to line up.
    test "[integration] the meter and the rung pill fold the same lanes" do
      GithubWorkflowRun.delete_all
      CiCheckJob.delete_all
      sha = "9248a9cfffffffffffffffffffffffffffffffff"
      nwo = "McRitchie-Studio/studio-engine"

      GithubWorkflowRun.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_400_001,
                                workflow_name: "Engine CI", status: "completed", conclusion: "success",
                                run_started_at: 6.minutes.ago, html_url: "https://x/1")
      GithubWorkflowRun.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_400_002,
                                workflow_name: "Consumer CI", status: "in_progress", conclusion: nil,
                                run_started_at: 5.minutes.ago, html_url: "https://x/2")

      3.times do |i|
        CiCheckJob.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_400_001,
                           job_id: 7_410_000 + i, workflow_name: "Engine CI", name: "engine #{i}",
                           status: "completed", conclusion: "success")
      end
      2.times do |i|
        CiCheckJob.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_400_002,
                           job_id: 7_420_000 + i, workflow_name: "Consumer CI", name: "consumer #{i}",
                           status: "in_progress", conclusion: nil)
      end

      rung = Ci::LadderRung.for(repo: "studio-engine", branch: "release")

      assert_equal :pending, rung.state, "the pill counts the running consumer lane"
      assert_equal 5, rung.progress.total, "and so does the meter — 3 engine checks + 2 consumer"
      assert_equal 3, rung.progress.passed
      assert_equal 2, rung.progress.pending
      assert_equal :pending, rung.progress.state,
                   "the meter's colour and the pill's state can no longer disagree"
      assert_equal "Consumer CI", rung.meter_lane_label, "the label names what is still running"

      # THE CASE THAT WAS MISSING, and the one that ships first. Seeding job rows for
      # BOTH lanes only ever exercised a fully-ingested SHA. There is NO BACKFILL — the
      # old allowlist dropped every sibling `workflow_job`, so on every historical SHA
      # the sibling has a RUN row and zero JOB rows, and the same window reopens on
      # every new run between `workflow_run` (queue time) and the first `workflow_job`.
      #
      # Folded by job rows alone, that lane vanishes from the meter while the label and
      # legend — which read RUN rows — keep naming it: a green 3/3 bar labelled
      # "Consumer CI" over a chip claiming it is counted, beside an amber pill.
      CiCheckJob.where(repo: nwo, workflow_name: "Consumer CI").delete_all
      rung = Ci::LadderRung.for(repo: "studio-engine", branch: "release")

      assert_equal 4, rung.progress.total,
                   "the un-ingested lane still contributes ONE run-grain mark — 3 engine jobs + 1"
      assert_equal :pending, rung.progress.state,
                   "so the meter cannot read green while the pill reads pending"
      assert_equal rung.state, rung.progress.state,
                   "pill and meter agree on a partially-ingested SHA, not just a complete one"
      assert_equal "Consumer CI", rung.meter_lane_label
      assert_equal ["Consumer CI", "Engine CI"], rung.legend_lanes.map { |l| l[:name] },
                   "every lane the card NAMES is a lane the meter COUNTS — the chip's title says so"
    end

    # A lane with neither job rows nor a run row is not a lane. The meter must stay
    # ABSENT rather than draw a hopeful zero — the guard the run-grain fallback must
    # not trample on its way past `rows.blank?`.
    test "[unit] a sha with no ingested runs at all still renders no meter" do
      GithubWorkflowRun.delete_all
      CiCheckJob.delete_all

      rung = Ci::LadderRung.new(repo: "studio-engine", branch: "release", state: :not_built,
                                sha: "deadbeef" + "0" * 32)

      assert_nil rung.progress, "no runs, no bar — an absence must never render as 0 of 0"
    end

    # The clock spans the COMMIT, not the lane that started last.
    test "[unit] the meter clock starts at the earliest lane on the sha" do
      GithubWorkflowRun.delete_all
      CiCheckJob.delete_all
      sha = "77e1a2bfffffffffffffffffffffffffffffffff"
      nwo = "McRitchie-Studio/studio-engine"
      first = 9.minutes.ago
      later = 4.minutes.ago

      GithubWorkflowRun.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_500_001,
                                workflow_name: "Engine CI", status: "completed", conclusion: "success",
                                run_started_at: first, html_url: "https://x/1")
      GithubWorkflowRun.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_500_002,
                                workflow_name: "Consumer CI", status: "in_progress", conclusion: nil,
                                run_started_at: later, html_url: "https://x/2")
      CiCheckJob.create!(repo: nwo, head_sha: sha, head_branch: "release", run_id: 7_500_001,
                         job_id: 7_510_001, workflow_name: "Engine CI", name: "engine suite",
                         status: "completed", conclusion: "success")

      rung = Ci::LadderRung.for(repo: "studio-engine", branch: "release")

      assert_in_delta first.to_i, rung.suite_started_at.to_i, 1,
                      "the earliest lane start is when this commit began being tested"
      assert_in_delta later.to_i, rung.verdict_at.to_i, 1,
                      "verdict_at keeps meaning the newest run — other readers depend on it"
      assert_in_delta first.to_i, rung.progress.started_at.to_i, 1,
                      "so the bar's clock measures the whole window, not the last lane to start"
    end

    test "a rung with no sha reports no lanes at all" do
      assert_empty Ci::LadderRung.new(repo: "turf-monster", branch: "main", state: :not_built).lanes
    end


    # --- criteria 3 and 4: what a rung is allowed to count -------------------

    def wf_run(repo:, branch:, sha:, workflow:, conclusion: "success", status: "completed", id: nil, started: nil)
      GithubWorkflowRun.create!(repo: "McRitchie-Studio/#{repo}", head_branch: branch, head_sha: sha,
                                run_id: id || rand(10**9), workflow_name: workflow,
                                status: status, conclusion: conclusion,
                                run_started_at: started || 5.minutes.ago,
                                html_url: "https://x/#{id || 1}")
    end

    # MEASURED 2026-08-20: sha ddfad29 carried runs on release AND main AND accepted.
    # BranchGate is sha-scoped, so every rung folded the same runs and the three badges
    # could never disagree — they carried no independent information at all.
    test "a rung folds only runs from its OWN branch" do
      GithubWorkflowRun.delete_all
      sha = "ddfad29aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "turf-monster", branch: "accepted", sha: sha, workflow: "CI", conclusion: "success", id: 1)
      wf_run(repo: "turf-monster", branch: "release",  sha: sha, workflow: "CI", conclusion: "failure", id: 2)

      assert_equal :green, Ci::LadderRung.for(repo: "turf-monster", branch: "accepted").state
      assert_equal :red,   Ci::LadderRung.for(repo: "turf-monster", branch: "release").state
    end

    # MEASURED 2026-08-20: 102 "Production Deploy" and 117 "QA Deploy" runs are
    # ingested. Folding them meant DEPLOYING moved a CI badge with no test having run.
    test "a deploy run never changes a rung state" do
      GithubWorkflowRun.delete_all
      sha = "deploy00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "turf-monster", branch: "main", sha: sha, workflow: "CI", conclusion: "success", id: 3)
      assert_equal :green, Ci::LadderRung.for(repo: "turf-monster", branch: "main").state

      wf_run(repo: "turf-monster", branch: "main", sha: sha, workflow: "Production Deploy",
             conclusion: "failure", id: 4)

      assert_equal :green, Ci::LadderRung.for(repo: "turf-monster", branch: "main").state,
                   "a failed DEPLOY must not redden a CI rung"
      refute_includes Ci::LadderRung.for(repo: "turf-monster", branch: "main").lanes.map { |l| l[:name] },
                      "Production Deploy", "and it must not be named as a lane either"
    end

    # --- the three the review named as missing -------------------------------

    # BLOCKER 1. `skipped` and `neutral` certify as "skipping" in CiStatus, not as a
    # failure. The previous fold read `conclusion != "success"` as red and drew them RED.
    test "a skipped run alongside a green suite run leaves the rung GREEN" do
      GithubWorkflowRun.delete_all
      sha = "skipped0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Engine CI",
             conclusion: "success", id: 20)
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Consumer CI",
             conclusion: "skipped", id: 21)

      assert_equal :green, Ci::LadderRung.for(repo: "studio-engine", branch: "main").state
    end

    test "a neutral run is skipping, not a failure" do
      GithubWorkflowRun.delete_all
      sha = "neutral0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Engine CI",
             conclusion: "success", id: 22)
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Consumer CI",
             conclusion: "neutral", id: 23)

      assert_equal :green, Ci::LadderRung.for(repo: "studio-engine", branch: "main").state
    end

    # …AND the companion rule. Widening the pass set without this reads an all-skipped
    # set as GREEN — a regression the old path never had (ci_status.rb:875).
    test "an all-skipped set certifies nothing and is NOT green" do
      GithubWorkflowRun.delete_all
      sha = "allskipaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Engine CI",
             conclusion: "skipped", id: 24)
      wf_run(repo: "studio-engine", branch: "main", sha: sha, workflow: "Consumer CI",
             conclusion: "skipped", id: 25)

      refute_equal :green, Ci::LadderRung.for(repo: "studio-engine", branch: "main").state
      assert_equal :not_built, Ci::LadderRung.for(repo: "studio-engine", branch: "main").state
    end

    # BLOCKER 2, the live one. "Devnet Nightly" is a daily SCHEDULE on turf-monster —
    # not a deploy, not a generated name — so the old deny-list admitted it. It both
    # voted in the fold and ANCHORED the rung's sha/run_url. 23 completed/skipped rows
    # on `main` drew a false RED for windows of 1.5h, 7.5h and 36h, and STATE_RANK[:red]
    # sorted that card to the TOP of the row.
    test "a scheduled non-suite workflow neither votes nor anchors" do
      GithubWorkflowRun.delete_all
      real = "realsuiteaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      nightly = "nightly0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "turf-monster", branch: "main", sha: real, workflow: "CI",
             conclusion: "success", id: 26, started: 3.hours.ago)
      # NEWER than the real suite run, so it would anchor if it counted.
      wf_run(repo: "turf-monster", branch: "main", sha: nightly, workflow: "Devnet Nightly",
             conclusion: "failure", id: 27, started: 1.minute.ago)

      rung = Ci::LadderRung.for(repo: "turf-monster", branch: "main")

      assert_equal :green, rung.state, "a nightly must not vote in a CI rung"
      assert_equal real[0, 7], rung.short_sha, "and must not anchor the rung's sha"
      refute_includes rung.lanes.map { |l| l[:name] }, "Devnet Nightly"
    end

    test "an undeclared workflow fails closed rather than counting as a verdict" do
      GithubWorkflowRun.delete_all
      sha = "codeql00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "turf-monster", branch: "accepted", sha: sha, workflow: "CodeQL",
             conclusion: "failure", id: 28)

      assert_equal :not_built, Ci::LadderRung.for(repo: "turf-monster", branch: "accepted").state,
                   "a workflow nobody declared as a suite is not a verdict"
    end

    test "a dependabot run is not a suite lane" do
      GithubWorkflowRun.delete_all
      sha = "dependbtaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "turf-monster", branch: "accepted", sha: sha, workflow: "CI", conclusion: "success", id: 5)
      wf_run(repo: "turf-monster", branch: "accepted", sha: sha,
             workflow: "bundler in / for stripe - Update #1534177382", conclusion: "failure", id: 6)

      assert_equal :green, Ci::LadderRung.for(repo: "turf-monster", branch: "accepted").state
    end

    # Fail-closed ordering: absence is not a pass, a failure beats a pending, a pending
    # beats a green.
    # Uses studio-engine because BOTH its lanes are declared suites — on turf-monster
    # only "CI" is, so a second workflow there is correctly excluded and could not
    # exercise the ordering.
    test "the fold is fail-closed in the right order" do
      assert_equal :not_built, Ci::LadderRung.fold([])
      GithubWorkflowRun.delete_all
      sha = "foldordraaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      wf_run(repo: "studio-engine", branch: "accepted", sha: sha, workflow: "Engine CI",
             conclusion: "success", id: 7)
      wf_run(repo: "studio-engine", branch: "accepted", sha: sha, workflow: "Consumer CI",
             conclusion: nil, status: "in_progress", id: 8)
      assert_equal :pending, Ci::LadderRung.for(repo: "studio-engine", branch: "accepted").state,
                   "an unsettled lane is no verdict yet"

      GithubWorkflowRun.find_by(run_id: 8).update!(status: "completed", conclusion: "failure")
      assert_equal :red, Ci::LadderRung.for(repo: "studio-engine", branch: "accepted").state,
                   "a failure beats the green beside it"
    end

    test "a branch with nothing ingested reads not_built" do
      GithubWorkflowRun.delete_all
      assert_equal :not_built, Ci::LadderRung.for(repo: "turf-monster", branch: "main").state
    end

    private

    def rung(state: :green, sha: "abc1234def", parked_count: 0)
      Ci::LadderRung.new(repo: "turf-monster", branch: "accepted", state: state,
                         sha: sha, verdict_at: 1.hour.ago, parked_count: parked_count)
    end
  end
end
