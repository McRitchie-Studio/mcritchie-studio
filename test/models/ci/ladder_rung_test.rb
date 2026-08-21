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

    test "uncounted_lanes names exactly what the meter cannot show" do
      GithubWorkflowRun.delete_all
      sha = "135e4e6ccccccccccccccccccccccccccccccccc"
      [["Engine CI", "success", 7_200_001], ["Consumer CI", "failure", 7_200_002]].each do |wf, concl, id|
        GithubWorkflowRun.create!(repo: "McRitchie-Studio/studio-engine", head_sha: sha,
                                  head_branch: "accepted", run_id: id, workflow_name: wf,
                                  status: "completed", conclusion: concl,
                                  run_started_at: 5.minutes.ago, html_url: "https://x/#{id}")
      end
      rung = Ci::LadderRung.new(repo: "studio-engine", branch: "accepted", state: :red, sha: sha)

      assert_equal "Engine CI", rung.counted_lane, "the meter counts the declared suite"
      assert_equal ["Consumer CI"], rung.uncounted_lanes.map { |l| l[:name] },
                   "the red sibling must be named on the card, not hidden"
      assert_equal :red, rung.uncounted_lanes.first[:state]
    end

    # An app runs one lane, so its card gains no extra line to read.
    test "a single lane repo reports nothing uncounted" do
      GithubWorkflowRun.delete_all
      sha = "abc1234ddddddddddddddddddddddddddddddddd"
      GithubWorkflowRun.create!(repo: "McRitchie-Studio/turf-monster", head_sha: sha,
                                head_branch: "release", run_id: 7_300_001, workflow_name: "CI",
                                status: "completed", conclusion: "success",
                                run_started_at: 5.minutes.ago, html_url: "https://x/1")
      rung = Ci::LadderRung.new(repo: "turf-monster", branch: "release", state: :green, sha: sha)

      assert_equal "CI", rung.counted_lane
      assert_empty rung.uncounted_lanes
    end

    test "a rung with no sha reports no lanes at all" do
      assert_empty Ci::LadderRung.new(repo: "turf-monster", branch: "main", state: :not_built).lanes
    end

    private

    def rung(state: :green, sha: "abc1234def", parked_count: 0)
      Ci::LadderRung.new(repo: "turf-monster", branch: "accepted", state: state,
                         sha: sha, verdict_at: 1.hour.ago, parked_count: parked_count)
    end
  end
end
