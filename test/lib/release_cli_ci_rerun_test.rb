# frozen_string_literal: true

# The release CI gate's ONE automatic re-run, as bin/release's poll spends it
# (poll_ci_verdict → ci_rerun_once! → ci_rerun_settled?). The decision itself is
# unit-tested in test/lib/ci_rerun_test.rb; these drive the real poll loop with the
# GitHub reads stubbed, so they prove the loop re-runs once, reads the re-run to its
# own conclusion, and treats a second red as real.
#
#   ruby -Itest test/lib/release_cli_ci_rerun_test.rb
#
# History: the re-run refused on an expired token (rel-20261105-9199b4), task
# release-reliability-papercuts.

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
                call: %($gate_sops = []; ci = poll_ci_verdict("rantly", #{SHA.inspect}, budget: 60); puts "STATE=\#{ci[:state]} RERUNS=\#{$reruns.inspect}"; puts "SOPS=\#{$gate_sops.inspect}"))
  end

  # [unit] THE FLAKE: red on attempt 1 → one re-run → the re-run's green certifies.
  def test_a_first_attempt_test_lane_red_is_rerun_once_and_its_green_passes
    out = poll(poll_stub(verdicts: [{ state: :red, failing: ["test"] }, { state: :pending }, { state: :green }]))

    assert_includes out, "AUTOMATIC RE-RUN, the one this gate allows"
    assert_includes out, "STATE=green"
    assert_includes out, 'RERUNS=["11"]', "exactly one `gh run rerun 11`"
    refute_includes out, "PARTIAL-RERUN", "every job re-runs, so the executed-set guards read fresh receipts"
    assert_includes out, %("sop"=>"ci_rerun"), "the re-run is recorded on the gate run, not only printed"
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

  # gh's real refusal on an expired App token (rel-20261105-9199b4's log line).
  EXPIRED = "HTTP 401: Bad credentials (https://api.github.com/repos/McRitchie-Studio/rantly/actions/runs/11/rerun)\n" \
            "Try authenticating with:  gh auth login"

  # The rerun stub refuses the ambient credential and accepts only the token the
  # harness broker (GH_AUTH_TOKEN_BIN, ReleaseCliStubs.token_broker) mints. $mints
  # counts the broker calls through GhAuthRetry.mint, which stays REAL.
  def expired_token_stub(**opts)
    poll_stub(**opts) + <<~RUBY
      $rerun_tokens = []
      def sh(*a, env: nil, **_k)
        return ["", true] unless a[0] == "gh" && a[1] == "run" && a[2] == "rerun"

        token = (env || {})["GH_TOKEN"]
        $rerun_tokens << (token ? "fresh" : "ambient")
        return [#{EXPIRED.inspect}, false] unless token == "stub-deployer-token"

        $reruns << a[3]
        ["", true]
      end
    RUBY
  end

  # [unit] THE 2026-11-05 REFUSAL: the ambient token expired during a long prepare.
  # The re-run is refused on credentials, a fresh token is minted, the re-run is
  # retried with it and goes through, and the token never reaches the output.
  def test_an_expired_token_is_refreshed_and_the_rerun_retried
    out = poll(expired_token_stub(verdicts: [{ state: :red, failing: ["test"] }, { state: :pending }, { state: :green }]) +
               %(\nat_exit { puts "TOKENS=\#{$rerun_tokens.inspect}" }\n))

    assert_includes out, 'TOKENS=["ambient", "fresh"]', "one refused try on the ambient token, one retry on the fresh one: #{out}"
    assert_includes out, 'RERUNS=["11"]', out
    assert_includes out, "STATE=green", out
    assert_includes out, "minted a fresh one and retried", out
    refute_includes out, "was refused", out
    refute_includes out, "stub-deployer-token", "the token must never be printed"
  end

  # [unit] THE CONTROL: with no token to mint, the refusal stands as before and
  # says why, so the refresh test above is not green by accident.
  def test_an_expired_token_with_no_mint_reads_the_red_as_it_stands
    setup = expired_token_stub(verdicts: [{ state: :red }]) + %(\nENV["GH_AUTH_TOKEN_BIN"] = "/nonexistent/gh-token"\n)
    out = poll(setup)

    assert_includes out, "no fresh token could be minted", out
    assert_includes out, "was refused", out
    assert_includes out, "STATE=red", out
    assert_includes out, "RERUNS=[]", out
  end

  # [unit] AGING, BEFORE THE CALL: the reads' held token (CiStatus) is past its 50
  # minutes when the re-run comes. The write re-mints FIRST and rides the new token,
  # so it is never refused at all. The broker numbers its tokens; gh accepts only #2.
  def test_an_aging_held_token_is_re_minted_before_the_rerun
    Dir.mktmpdir do |dir|
      broker = File.join(dir, "gh-token")
      File.write(broker, "#!/bin/sh\nn=$(( $(cat #{dir}/n 2>/dev/null || echo 0) + 1 ))\necho $n > #{dir}/n\necho ghs_stub_$n\n")
      File.chmod(0o755, broker)
      setup = poll_stub(verdicts: [{ state: :red, failing: ["test"] }, { state: :pending }, { state: :green }]) + <<~RUBY
        ENV["GH_AUTH_TOKEN_BIN"] = #{broker.inspect}
        $sim = 0
        CiStatus.reset_gh_auth!
        CiStatus.clock = -> { $sim }
        CiStatus.mint_gh_token!          # the reads' token, minted at t=0
        $sim = 3_300                     # 55 minutes later: aging
        $rerun_tokens = []
        def sh(*a, env: nil, **_k)
          return ["", true] unless a[0] == "gh" && a[1] == "run" && a[2] == "rerun"

          token = (env || {})["GH_TOKEN"].to_s
          $rerun_tokens << "mint#" + token.delete_prefix("ghs_stub_")
          return [#{EXPIRED.inspect}, false] unless token == "ghs_stub_2"

          $reruns << a[3]
          ["", true]
        end
        at_exit { puts "TOKENS=\#{$rerun_tokens.inspect}" }
      RUBY
      out = poll(setup)

      assert_includes out, 'TOKENS=["mint#2"]', "one try, on the token re-minted before the call: #{out}"
      assert_includes out, 'RERUNS=["11"]', out
      refute_includes out, "was refused", out
      refute_includes out, "ghs_stub", "the token must never be printed"
    end
  end

  # [unit] A refusal that is not about credentials mints nothing and retries nothing.
  def test_a_non_credential_refusal_mints_no_token
    setup = poll_stub(verdicts: [{ state: :red }]) + <<~RUBY
      $tries = 0
      def sh(*a, **_k)
        return ["", true] unless a[0] == "gh" && a[1] == "run" && a[2] == "rerun"

        $tries += 1
        ["run 11 cannot be rerun; its workflow file may be broken", false]
      end
      at_exit { puts "TRIES=\#{$tries}" }
    RUBY
    out = poll(setup)

    assert_includes out, "TRIES=1", out
    refute_includes out, "minted a fresh one", out
    assert_includes out, "was refused", out
  end

  def test_the_rerun_is_disarmed_by_env_and_by_the_injected_verdict_seam
    off = poll(poll_stub(verdicts: [{ state: :red }]) + %(\nENV["RELEASE_CI_RERUN"] = "off"\n))
    assert_includes off, "RERUNS=[]"

    injected = run_cli([], setup: %(ENV["RELEASE_CI_STATUS"] = "red"; ENV["RELEASE_CI_POLL_INTERVAL"] = "0"),
                           call: %(ci = poll_ci_verdict("rantly", #{SHA.inspect}, budget: 5); puts "STATE=\#{ci[:state]}"))
    assert_includes injected, "STATE=red"
    refute_includes injected, "AUTOMATIC RE-RUN"
  end

  # The run's states in order, one per ci_workflow_runs read (the last repeats), and
  # what it reads after the re-run is requested.
  def sequenced_stub(verdicts:, runs_seq:, runs_after:, jobs: ["test"])
    <<~RUBY
      ENV.delete("RELEASE_CI_STATUS")
      ENV["RELEASE_CI_POLL_INTERVAL"] = "0"
      $verdicts = #{verdicts.inspect}
      $runs_seq = #{runs_seq.inspect}
      $reruns = []
      def ci_verdict(_repo, _sha) = ($verdicts.size > 1 ? $verdicts.shift : $verdicts.first)
      def repo_name_with_owner(_repo) = "McRitchie-Studio/turf-monster"
      def ci_workflow_runs(_nwo, _sha)
        return #{runs_after.inspect} unless $reruns.empty?

        $runs_seq.size > 1 ? $runs_seq.shift : $runs_seq.first
      end
      def ci_failed_job_names(_nwo, _id) = #{jobs.inspect}
      def ci_failed_log(_nwo, _id) = "Offenses: 1"
      def sh(*a, **_k)
        if a[0] == "gh" && a[1] == "run" && a[2] == "rerun"
          $reruns << a[3]
          return ["", true]
        end
        ["", true]
      end
    RUBY
  end

  def row(status:, conclusion:, attempt: 1)
    [{ "id" => 21, "name" => "CI", "conclusion" => conclusion, "run_attempt" => attempt, "event" => "push",
       "status" => status, "head_sha" => SHA }]
  end

  # [unit] THE 2026-10-27 READ: a job went red while its workflow run was still in
  # progress. The gate holds for the run to complete, THEN spends the one re-run,
  # instead of printing "no failed workflow run found" and failing.
  def test_a_red_read_while_the_run_is_still_in_progress_waits_for_completion_then_reruns
    setup = sequenced_stub(
      verdicts: [{ state: :red }, { state: :red }, { state: :red }, { state: :pending }, { state: :green }],
      runs_seq: [row(status: "in_progress", conclusion: nil), row(status: "in_progress", conclusion: nil),
                 row(status: "completed", conclusion: "failure")],
      runs_after: row(status: "completed", conclusion: "success", attempt: 2)
    )
    out = poll(setup)

    assert_includes out, "still in progress — holding for the run to complete", out
    assert_equal 1, out.scan("still in progress").size, "said once, not on every read"
    refute_includes out, "no failed workflow run found", out
    assert_includes out, "AUTOMATIC RE-RUN", out
    assert_includes out, 'RERUNS=["21"]', out
    assert_includes out, "STATE=green", out
  end

  # [unit] THE RE-LOCK GATE: a commit measured to differ from the QA-green tree in
  # Gemfile.lock alone re-runs a first-attempt red in a NON-test job once, and a red
  # after that re-run is refused, never re-run a second time.
  def test_the_relock_only_gate_reruns_a_failed_job_once_and_refuses_a_second_time
    setup = sequenced_stub(verdicts: [{ state: :red }], jobs: ["lint"],
                           runs_seq: [row(status: "completed", conclusion: "failure")],
                           runs_after: row(status: "completed", conclusion: "failure", attempt: 2)) +
            %(\nci_rerun_relock_shas[["turf-monster", #{SHA.inspect}]] = true\n)
    out = run_cli([], setup: setup, call: <<~CALL)
      first = poll_ci_verdict("turf-monster", #{SHA.inspect}, budget: 60)
      second = poll_ci_verdict("turf-monster", #{SHA.inspect}, budget: 0)
      puts "STATE=\#{first[:state]}/\#{second[:state]} RERUNS=\#{$reruns.inspect}"
    CALL

    assert_includes out, "re-lock commit", out
    assert_includes out, "a second red is real", out
    assert_includes out, 'RERUNS=["21"]', "one re-run, never a second: #{out}"
    assert_includes out, "STATE=red/red", out
  end

  # [unit] Off a re-lock commit the same lint red is a finding: no re-run.
  def test_without_the_relock_mark_a_lint_red_is_not_rerun
    setup = sequenced_stub(verdicts: [{ state: :red }], jobs: ["lint"],
                           runs_seq: [row(status: "completed", conclusion: "failure")],
                           runs_after: row(status: "completed", conclusion: "failure", attempt: 2))
    out = poll(setup)

    assert_includes out, "RERUNS=[]", out
  end

  # [unit] The mark is MEASURED: a diff past the QA-green tree that touches code
  # leaves the ordinary rule in force.
  def test_mark_relock_only_reads_the_diff
    setup = <<~RUBY
      $names = "Gemfile.lock\n"
      def git_capture(*args) = (args.include?("diff") ? [$names, true] : ["", false])
      def repo_path(_repo) = "/stub"
    RUBY
    out = run_cli([], setup: setup, call: <<~CALL)
      a = mark_relock_only!("turf-monster", { "from" => "f" * 40 }, "1" * 40)
      $names = "Gemfile.lock\napp/models/x.rb\n"
      b = mark_relock_only!("turf-monster", { "from" => "f" * 40 }, "2" * 40)
      puts "MARKS=\#{a.inspect}/\#{b.inspect} \#{ci_rerun_relock_shas.keys.map(&:last).map { |s| s[0] }.inspect}"
    CALL

    assert_includes out, 'MARKS=true/false ["1"]', out
  end
end
