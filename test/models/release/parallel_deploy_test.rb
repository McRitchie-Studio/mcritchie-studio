# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# The concurrent satellite deploys (Release::ParallelDeploy): the hub-first order
# that stays, the partial-failure semantics, and the prefixed output.
class Release::ParallelDeployTest < ActiveSupport::TestCase
  PD = Release::ParallelDeploy

  def groups(*repos) = repos.map { |r| { "repo" => r } }

  # [unit] THE ORDER THAT STAYS: the hub alone first, the rest after, in order.
  def test_waves_put_the_hub_first_and_alone
    hub, rest = PD.waves(groups("turf-monster", "mcritchie-studio", "rantly"))

    assert_equal ["mcritchie-studio"], hub.map { |g| g["repo"] }
    assert_equal %w[turf-monster rantly], rest.map { |g| g["repo"] }
    assert_equal [[], ["rantly"]], PD.waves(groups("rantly")).map { |w| w.map { |g| g["repo"] } }
  end

  def test_concurrency_defaults_and_clamps_to_the_board_cap
    assert_equal 3, PD.concurrency(nil)
    assert_equal 3, PD.concurrency("junk")
    assert_equal 1, PD.concurrency("0")
    assert_equal 4, PD.concurrency("9"), "the conductor is the fifth board writer"
  end

  # [unit] PARTIAL FAILURE: one app's abort (a SystemExit, as bin/release's abort!
  # raises) fails that app only; every other app runs to its end and is live.
  def test_one_failing_app_neither_stops_nor_rolls_back_the_others
    ran = Queue.new
    results = PD.run(groups("turf-monster", "rantly", "moms-app"), concurrency: 3) do |group|
      ran << group["repo"]
      # What bin/release's abort! raises (Kernel#abort also prints it to $stderr).
      raise SystemExit.new(1, "✗ turf-monster deploy script failed (bin/deploy)") if group["repo"] == "turf-monster"
    end

    assert_equal %w[moms-app rantly turf-monster], Array.new(ran.size) { ran.pop }.sort, "every app ran"
    assert_equal %w[rantly moms-app], PD.live(results).map(&:repo)
    assert_equal ["turf-monster"], PD.failed(results).map(&:repo)
    assert_equal "turf-monster deploy script failed (bin/deploy)", PD.failed(results).first.error
  end

  def test_a_raised_error_is_a_failure_too_and_results_keep_the_input_order
    results = PD.run(groups("a", "b"), concurrency: 2) { |g| raise ArgumentError, "boom" if g["repo"] == "a" }

    assert_equal %w[a b], results.map(&:repo)
    assert_equal "ArgumentError: boom", results.first.error
    assert results.last.ok
  end

  # [unit] Actually concurrent: two jobs that each wait for the other finish only
  # if they run at the same time.
  def test_jobs_run_concurrently_up_to_the_limit
    gate = Queue.new
    results = PD.run(groups("a", "b"), concurrency: 2) do |g|
      gate << g["repo"]
      deadline = Time.now + 5
      sleep 0.01 until gate.size >= 2 || Time.now > deadline
      raise "ran alone" if gate.size < 2
    end

    assert results.all?(&:ok), results.map(&:error).inspect
  end

  def test_the_limit_bounds_how_many_run_at_once
    live = 0
    peak = 0
    lock = Mutex.new
    PD.run(groups("a", "b", "c", "d", "e"), concurrency: 2) do
      lock.synchronize { live += 1; peak = [peak, live].max }
      sleep 0.05
      lock.synchronize { live -= 1 }
    end

    assert_equal 2, peak
  end

  # [unit] The record a partial ship leaves: what is live, what failed, how to resume.
  def test_failure_message_names_live_and_failed_apps_and_the_resume
    results = [PD::Result.new(repo: "rantly", ok: true, seconds: 40),
               PD::Result.new(repo: "turf-monster", ok: false, error: "smoke failed", seconds: 300)]
    text = PD.failure_message(results, resume_cmd: "bin/release ship")

    assert_includes text, "1 of 2 satellite deploys FAILED (turf-monster)"
    assert_includes text, "LIVE on production: rantly"
    assert_includes text, "NOTHING was rolled back elsewhere"
    assert_includes text, "skips every app already live and deploys only the unfinished ones"
    assert_nil PD.failure_message([results.first])
    assert_includes PD.summary_lines(results).last, "✗ FAILED turf-monster (300s) — smoke failed"
  end

  # [unit] OUTPUT: each deploying thread's lines are prefixed and logged per app; a
  # partial line is held until it completes; the conductor's own writes pass through.
  def test_prefixed_output_prefixes_and_logs_per_app_and_passes_the_conductor_through
    sink = StringIO.new
    Dir.mktmpdir do |dir|
      out = PD::PrefixedOutput.new(sink)
      PD.run(groups("rantly", "moms-app"), concurrency: 2, log_dir: dir) do |g|
        out.print("deploy ")
        out.puts("#{g['repo']} start")
        out.write("no newline")
      end
      out.puts("conductor line")

      lines = sink.string.lines.map(&:chomp)
      assert_includes lines, "[rantly] deploy rantly start"
      assert_includes lines, "[moms-app] deploy moms-app start"
      assert_includes lines, "[rantly] no newline", "a trailing partial line is flushed when the job ends"
      assert_includes lines, "conductor line"
      assert_equal "deploy rantly start\nno newline\n", File.read(File.join(dir, "rantly.log"))
    end
  end

  def test_with_prefixed_output_restores_the_real_streams
    before = $stdout
    PD.with_prefixed_output { assert_kind_of PD::PrefixedOutput, $stdout }
    assert_same before, $stdout
  end
end
