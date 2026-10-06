# frozen_string_literal: true

# The release gates' POLL BUDGET on a pending CI verdict, sized from the workflows that
# produce it (bin/lib/ci_poll_budget.rb, bin/release.rb ci_poll_budget_for).
#
# THE DEFECT (task gem-gate-outwaits-consumer-ci). The gem publish gate polled a flat
# 1200 s, but studio-engine's verdict carries Consumer CI (refs -> hub shards, turf,
# industries -> aggregate) and the browser lane, which take longer on a fresh release
# tip. Every release sweep on 2026-10-05/06 aborted with "GitHub CI is pending" and
# needed a manual re-run once CI went green.
#
# A new file beside its subcommand, over the shared harness, rather than an append to a
# frozen release CLI file. Run directly:
#   ruby -Itest test/lib/release_cli_ci_poll_budget_test.rb

require_relative "release_cli_harness"
require_relative "../../bin/lib/ci_poll_budget"

# The shape of studio-engine's Consumer CI as of 2026-10-06: a 5-minute refs job, the
# consumer suites (45) after it, and an aggregate (45) after both. Its chain is 95 min.
CONSUMER_CI_SHAPE = <<~YAML
  name: Consumer CI
  on: [push]
  jobs:
    consumer-refs:
      runs-on: ubuntu-latest
      timeout-minutes: 5
    consumer-tests:
      needs: consumer-refs
      runs-on: ubuntu-latest
      timeout-minutes: 45
    consumer-ci:
      needs: [consumer-refs, consumer-tests]
      runs-on: ubuntu-latest
      timeout-minutes: 45
YAML

class CiPollBudgetTest < Minitest::Test
  def test_the_chain_is_the_longest_needs_path_of_job_timeouts
    assert_equal 95, CiPollBudget.critical_path_minutes(CONSUMER_CI_SHAPE)
  end

  # [unit] THE ACCEPTANCE: the budget covers the engine workflow's longest job chain,
  # and is far above the flat 1200 s window that timed out every sweep.
  def test_the_budget_covers_the_consumer_chain_and_outlives_the_flat_window
    budget = CiPollBudget.budget_s([CONSUMER_CI_SHAPE], floor: 1200, ceiling: 7200)

    assert_operator budget, :>=, 95 * 60, "the gate must outwait the workflow it reads"
    assert_operator budget, :>, 1200
  end

  def test_parallel_workflows_budget_for_the_slowest_one
    fast = "on: push\njobs:\n  a:\n    timeout-minutes: 10\n"

    assert_equal (95 * 60) + CiPollBudget::HEADROOM_S,
                 CiPollBudget.budget_s([fast, CONSUMER_CI_SHAPE], floor: 0, ceiling: 99_999)
  end

  # A job with no timeout runs to GitHub's 360-minute default; the ceiling bounds it.
  def test_a_job_without_a_timeout_counts_as_githubs_default_and_the_ceiling_caps_it
    assert_equal 360, CiPollBudget.critical_path_minutes("jobs:\n  a:\n    runs-on: x\n")
    assert_equal 7200, CiPollBudget.budget_s(["on: push\njobs:\n  a:\n    runs-on: x\n"], floor: 1200, ceiling: 7200)
  end

  # [unit] ONLY GATING WORKFLOWS SIZE THE WAIT (task ci-poll-refreshes-its-token). A
  # schedule- or dispatch-only workflow never runs on the SHA under test, so its chain,
  # however long, must not widen the hold.
  NIGHTLY = "name: devnet-nightly\non:\n  schedule:\n    - cron: '0 6 * * *'\n  workflow_dispatch:\n" \
            "jobs:\n  nightly:\n    runs-on: x\n"

  def test_a_schedule_only_workflow_does_not_size_the_budget
    assert_equal 360, CiPollBudget.critical_path_minutes(NIGHTLY), "its chain alone would hit the ceiling"
    assert_equal (95 * 60) + CiPollBudget::HEADROOM_S,
                 CiPollBudget.budget_s([NIGHTLY, CONSUMER_CI_SHAPE], floor: 0, ceiling: 99_999)
    assert_equal 1200, CiPollBudget.budget_s([NIGHTLY], floor: 1200, ceiling: 7200)
  end

  # Every `on:` spelling GitHub accepts. Psych reads a bare `on` as the boolean true,
  # which is why CONSUMER_CI_SHAPE's `on: [push]` is the case that proves the key read.
  def test_gating_reads_every_on_spelling
    assert CiPollBudget.gating?(CONSUMER_CI_SHAPE)
    assert CiPollBudget.gating?("on: pull_request\njobs: {}\n")
    assert CiPollBudget.gating?("on:\n  push:\n    branches: [accepted]\njobs: {}\n")
    assert CiPollBudget.gating?("'on': [workflow_dispatch, push]\njobs: {}\n")
    refute CiPollBudget.gating?("on: [schedule, workflow_dispatch]\njobs: {}\n")
    refute CiPollBudget.gating?("on:\n  workflow_run:\n    workflows: [CI]\njobs: {}\n")
    refute CiPollBudget.gating?("jobs:\n  a:\n    runs-on: x\n"), "no trigger: GitHub never runs it"
    refute CiPollBudget.gating?(": : not yaml [")
  end

  # UNKNOWN NEVER WIDENS: nothing readable keeps the operator's floor exactly.
  def test_unreadable_or_jobless_workflows_keep_the_floor
    assert_nil CiPollBudget.critical_path_minutes(": : not yaml [")
    assert_nil CiPollBudget.critical_path_minutes("name: no jobs\n")
    assert_equal 1200, CiPollBudget.budget_s([], floor: 1200, ceiling: 7200)
    assert_equal 1200, CiPollBudget.budget_s([": : not yaml ["], floor: 1200, ceiling: 7200)
  end

  def test_the_floor_wins_when_the_operator_widened_past_the_chain
    assert_equal 9000, CiPollBudget.budget_s([CONSUMER_CI_SHAPE], floor: 9000, ceiling: 7200)
  end

  def test_a_needs_cycle_does_not_hang_or_raise
    cyclic = "jobs:\n  a:\n    needs: b\n    timeout-minutes: 5\n  b:\n    needs: a\n    timeout-minutes: 5\n"

    assert_kind_of Integer, CiPollBudget.critical_path_minutes(cyclic)
  end
end

# [integration] The REAL bin/release gem gate, driven through the harness subprocess,
# against a real git repo whose tip carries the workflow it waits on.
class ReleaseCliCiPollBudgetTest < ReleaseCliHarness
  # A one-commit repo whose tree carries `workflows` under .github/workflows/.
  def workflow_repo(dir, workflows)
    repo = File.join(dir, "gem")
    FileUtils.mkdir_p(File.join(repo, ".github", "workflows"))
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL) || flunk("git init failed")
    workflows.each { |name, text| File.write(File.join(repo, ".github", "workflows", name), text) }
    File.write(File.join(repo, "README"), "fixture")
    run_git(repo, "add", ".")
    run_git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
    [repo, git_out(repo, "rev-parse", "HEAD")]
  end

  # The flat window is collapsed to ONE read (RELEASE_CI_POLL_TIMEOUT=0), exactly the
  # shape of the bug: CI that outlives the flat window. ci_verdict answers `verdicts`
  # in turn and then repeats the last; $ci_reads counts the reads.
  def gem_gate(repo, sha, verdicts)
    run_ruby(<<~RUBY)
      ENV["RELEASE_CI_POLL_INTERVAL"] = "0"
      ENV["RELEASE_CI_POLL_TIMEOUT"] = "0"
      ENV.delete("RELEASE_CI_STATUS")
      ARGV.replace([])
      load #{BIN.inspect}
      def repo_path(_repo) = #{repo.inspect}
      $ci_reads = 0
      $verdicts = #{verdicts.inspect}
      def ci_verdict(_repo, _sha)
        $ci_reads += 1
        $verdicts[[$ci_reads, $verdicts.size].min - 1]
      end
      puts "BUDGET=\#{ci_poll_budget_for("studio-engine", #{sha.inspect})}"
      puts "RESULT=\#{gem_ci_failure("studio-engine", #{sha.inspect}, "0.99.0").inspect}"
      puts "READS=\#{$ci_reads}"
    RUBY
  end

  PENDING_THEN_GREEN = [{ state: :pending, pending: ["consumer-ci"] },
                        { state: :pending, pending: ["consumer-ci"] },
                        { state: :green, count: 9 }].freeze

  # [integration] THE FIX: a pending verdict that outlives the flat window is HELD,
  # and the gate passes once CI goes green, with no manual re-run.
  def test_a_pending_gem_gate_outwaits_the_flat_window_and_passes_on_green
    Dir.mktmpdir do |dir|
      repo, sha = workflow_repo(dir, "consumer-ci.yml" => CONSUMER_CI_SHAPE)
      out = gem_gate(repo, sha, PENDING_THEN_GREEN)

      assert_includes out, "BUDGET=#{(95 * 60) + CiPollBudget::HEADROOM_S}"
      assert_includes out, "RESULT=nil", "a pending verdict that later goes green must pass the gate: #{out}"
      assert_includes out, "READS=3", "the gate must have HELD across reads, not decided on the first"
    end
  end

  # STILL FAIL-CLOSED ON RED: the wider budget never delays a red verdict.
  def test_red_still_aborts_on_the_first_read
    Dir.mktmpdir do |dir|
      repo, sha = workflow_repo(dir, "consumer-ci.yml" => CONSUMER_CI_SHAPE)
      out = gem_gate(repo, sha, [{ state: :red, failing: ["consumer-ci"] }])

      assert_includes out, "NOTHING WAS PUBLISHED"
      assert_includes out, "READS=1"
    end
  end

  # NO READABLE WORKFLOW KEEPS THE FLOOR: the old behaviour, exactly.
  def test_a_tip_with_no_workflows_keeps_the_flat_window
    Dir.mktmpdir do |dir|
      repo, sha = workflow_repo(dir, {})
      out = gem_gate(repo, sha, PENDING_THEN_GREEN)

      assert_includes out, "BUDGET=0"
      assert_includes out, "NOTHING WAS PUBLISHED"
      assert_includes out, "READS=1"
    end
  end
end
