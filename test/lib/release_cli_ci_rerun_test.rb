# frozen_string_literal: true

# The release CI gate's ONE automatic re-run, as bin/release's poll spends it
# (poll_ci_verdict → ci_rerun_once! → ci_rerun_settled?). The decision itself is
# unit-tested in test/lib/ci_rerun_test.rb; these drive the real poll loop with the
# GitHub reads stubbed, so they prove the loop re-runs once, reads the re-run to its
# own conclusion, and treats a second red as real.
#
#   ruby -Itest test/lib/release_cli_ci_rerun_test.rb

require_relative "release_cli_harness"

class ReleaseCliCiRerunTest < ReleaseCliHarness
  SHA = "c" * 40

  # `verdicts` are read in order (the last repeats); `runs_before`/`runs_after` are the
  # workflow runs GitHub reports before and after the re-run is requested.
  def poll_stub(verdicts:, jobs: ["test"], runs_before: nil, runs_after: nil, rerun_ok: true, log: "")
    runs_before ||= [{ "id" => 11, "name" => "CI", "conclusion" => "failure", "run_attempt" => 1,
                       "event" => "push", "status" => "completed", "head_sha" => SHA }]
    runs_after ||= [{ "id" => 11, "name" => "CI", "conclusion" => "success", "run_attempt" => 2,
                      "event" => "push", "status" => "completed", "head_sha" => SHA }]
    <<~RUBY
      ENV.delete("RELEASE_CI_STATUS")
      ENV["RELEASE_CI_POLL_INTERVAL"] = "0"
      $verdicts = #{verdicts.inspect}
      $reruns = []
      def ci_verdict(_repo, _sha) = ($verdicts.size > 1 ? $verdicts.shift : $verdicts.first)
      def repo_name_with_owner(_repo) = "McRitchie-Studio/rantly"
      def ci_workflow_runs(_nwo, _sha) = ($reruns.empty? ? #{runs_before.inspect} : #{runs_after.inspect})
      def ci_failed_job_names(_nwo, _id) = #{jobs.inspect}
      def ci_failed_log(_nwo, _id) = #{log.inspect}
      def sh(*a, **_k)
        if a[0] == "gh" && a[1] == "run" && a[2] == "rerun"
          $reruns << a[3]
          $stdout.puts("PARTIAL-RERUN") if a.include?("--failed")
          return ["", #{rerun_ok}]
        end
        ["", true]
      end
    RUBY
  end

  def poll(setup)
    run_cli([], setup: setup,
                call: %(ci = poll_ci_verdict("rantly", #{SHA.inspect}, budget: 60); puts "STATE=\#{ci[:state]} RERUNS=\#{$reruns.inspect}"))
  end

  # [unit] THE FLAKE: red on attempt 1 → one re-run → the re-run's green certifies.
  def test_a_first_attempt_test_lane_red_is_rerun_once_and_its_green_passes
    out = poll(poll_stub(verdicts: [{ state: :red, failing: ["test"] }, { state: :pending }, { state: :green }]))

    assert_includes out, "AUTOMATIC RE-RUN, the one this gate allows"
    assert_includes out, "STATE=green"
    assert_includes out, 'RERUNS=["11"]', "exactly one `gh run rerun 11`"
    refute_includes out, "PARTIAL-RERUN", "every job re-runs, so the executed-set guards read fresh receipts"
  end

  # [unit] A SECOND RED IS REAL: the re-run concluded red, so the gate fails on it.
  def test_a_second_red_after_the_rerun_is_real
    runs_after = [{ "id" => 11, "conclusion" => "failure", "run_attempt" => 2, "event" => "push",
                    "status" => "completed", "head_sha" => SHA }]
    out = poll(poll_stub(verdicts: [{ state: :red, failing: ["test"] }], runs_after: runs_after))

    assert_includes out, "a second red is real"
    assert_includes out, "STATE=red"
    assert_includes out, 'RERUNS=["11"]', "never a second re-run"
  end

  # [unit] The old attempt's red is still on the SHA until GitHub picks the re-run up.
  def test_the_first_attempts_red_is_not_read_as_the_second_verdict
    still_old = [{ "id" => 11, "conclusion" => "failure", "run_attempt" => 1, "event" => "push",
                   "status" => "completed", "head_sha" => SHA }]
    setup = poll_stub(verdicts: [{ state: :red }, { state: :red }, { state: :red }, { state: :green }],
                      runs_after: still_old)
    out = poll(setup)

    refute_includes out, "RED again", "an unsettled re-run must not close the gate"
    assert_includes out, "STATE=green"
  end

  # [unit] ONCE PER SHA PER PROCESS: a second gate reading the same SHA (a resumed
  # poll, a second read of the frozen tree) gets no second re-run.
  def test_a_second_poll_of_the_same_sha_spends_no_second_rerun
    runs_after = [{ "id" => 11, "conclusion" => "failure", "run_attempt" => 2, "event" => "push",
                    "status" => "completed", "head_sha" => SHA }]
    setup = poll_stub(verdicts: [{ state: :red, failing: ["test"] }], runs_after: runs_after) +
            # A fresh first attempt again, as if a different run had failed on the same SHA.
            %(\ndef ci_workflow_runs(_nwo, _sha) = [{ "id" => 12, "conclusion" => "failure", "run_attempt" => 1, ) +
            %("event" => "push", "status" => "completed", "head_sha" => #{SHA.inspect} }]\n)
    out = run_cli([], setup: setup, call: <<~CALL)
      poll_ci_verdict("rantly", #{SHA.inspect}, budget: 0)
      poll_ci_verdict("rantly", #{SHA.inspect}, budget: 0)
      puts "RERUNS=\#{$reruns.inspect}"
    CALL

    assert_includes out, 'RERUNS=["12"]', "one re-run for the SHA across both polls: #{out}"
  end

  def test_a_real_lint_failure_is_not_rerun
    out = poll(poll_stub(verdicts: [{ state: :red, failing: ["lint"] }], jobs: ["lint"], log: "Offenses: 2"))

    assert_includes out, "no automatic re-run (CI (run 11) failed in lint, which is not a test lane"
    assert_includes out, "STATE=red"
    assert_includes out, "RERUNS=[]"
  end

  # [unit] THE CDN RACE: lint/scan_js died on bundler's resolution error → re-run.
  def test_the_gem_resolution_error_is_rerun_even_in_a_non_test_job
    log = "studio-engine (0.114.1) ... can no longer be found in that source"
    out = poll(poll_stub(verdicts: [{ state: :red }, { state: :green }], jobs: %w[scan_js lint], log: log))

    assert_includes out, "gem-resolution error"
    assert_includes out, "STATE=green"
  end

  def test_a_refused_rerun_reads_the_red_as_it_stands
    out = poll(poll_stub(verdicts: [{ state: :red }], rerun_ok: false))

    assert_includes out, "was refused"
    assert_includes out, "STATE=red"
  end

  def test_the_rerun_is_disarmed_by_env_and_by_the_injected_verdict_seam
    off = poll(poll_stub(verdicts: [{ state: :red }]) + %(\nENV["RELEASE_CI_RERUN"] = "off"\n))
    assert_includes off, "RERUNS=[]"

    injected = run_cli([], setup: %(ENV["RELEASE_CI_STATUS"] = "red"; ENV["RELEASE_CI_POLL_INTERVAL"] = "0"),
                           call: %(ci = poll_ci_verdict("rantly", #{SHA.inspect}, budget: 5); puts "STATE=\#{ci[:state]}"))
    assert_includes injected, "STATE=red"
    refute_includes injected, "AUTOMATIC RE-RUN"
  end
end
