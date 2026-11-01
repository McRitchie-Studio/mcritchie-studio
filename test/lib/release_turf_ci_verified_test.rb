# frozen_string_literal: true

# TURF READS THE CI VERDICT INSTEAD OF RE-RUNNING ITS SUITE. turf registers test_cmd, so the
# ship READS GitHub CI's verdict for the SHA it deploys (test_gate, frozen and re-lock), and
# only a green read for EXACTLY that SHA makes deploy_app append the declared `ci_verified_arg`
# (`--ci-verified=<sha>`).
# History: task faster-steadier-production-ship.

require_relative "release_cli_harness"

class ReleaseTurfCiVerifiedTest < ReleaseCliHarness
  FROZEN = "f" * 40
  OTHER  = "e" * 40

  def gate_stub(state)
    <<~RUBY
      def app_meta_for(_repo) = { "test_cmd" => "bin/rails db:test:prepare test" }
      def resolve_release_ci_verdict(_repo, _path, _sha, budget: 0)
        { ci: { state: #{state.inspect} }, credited: false, diagnostic: nil, diverged: true }
      end
    RUBY
  end

  def run_gate(setup, argv: ["--yes"])
    run_cli(argv, setup: setup, call: <<~CALL)
      $gate_sops = []
      begin
        test_gate("turf-monster", frozen_sha: #{FROZEN.inspect})
      rescue SystemExit => e
        puts "ABORTED"
      end
      puts "GREEN=\#{ci_green_shas.inspect}"
    CALL
  end

  # [unit] A green read records the exact SHA it certified.
  def test_a_green_gate_read_records_the_sha_it_certified
    out = run_gate(gate_stub(:green))

    refute_includes out, "self-gates", "turf is read, not skipped"
    assert_match(/GREEN=\{"turf-monster" ?=> ?"#{FROZEN}"\}/, out)
  end

  # [unit] NEVER SKIP TESTS WITHOUT A GREEN VERDICT: red, held and skipped gates record nothing.
  def test_a_red_or_held_read_records_nothing
    %i[red pending].each do |state|
      out = run_gate(gate_stub(state))
      assert_includes out, "ABORTED", "#{state} fails the gate"
      assert_includes out, "GREEN={}", "#{state} never vouches for a deploy"
    end
  end

  def test_an_operator_skipped_gate_records_nothing
    out = run_gate(gate_stub(:green), argv: ["--yes", "--skip-test-gate", "--reason", "CI is down"])

    assert_includes out, "SKIPPED BY OPERATOR"
    assert_includes out, "GREEN={}", "a skipped read is not a green read — turf then runs its own suite"
  end

  def args_for(green_sha, flag: "--ci-verified")
    adapter = flag ? { "ci_verified_arg" => flag } : {}
    run_cli([], setup: green_sha ? %(ci_green_shas["turf-monster"] = #{green_sha.inspect}) : "",
                call: %(p ci_verified_args("turf-monster", #{adapter.inspect}, #{FROZEN.inspect})))
  end

  # [unit] The flag rides only on a green read for THIS SHA, and only when declared.
  def test_the_flag_is_passed_only_for_a_green_read_of_the_same_sha
    assert_includes args_for(FROZEN), %(["--ci-verified=#{FROZEN}"])
    assert_includes args_for(OTHER), "[]", "a green read of another SHA (the pre-re-lock tree) does not vouch"
    assert_includes args_for(nil), "[]", "no read, no flag"
    assert_includes args_for(FROZEN, flag: nil), "[]", "an undeclared flag is never invented"
  end

  # [integration] deploy_app hands the flag to the repo's own script, in its ship workspace.
  def test_deploy_app_appends_the_flag_to_the_repo_script_only_after_a_green_read
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")
      probe  = File.join(dir, "probe.sh")
      File.write(probe, "#!/usr/bin/env sh\necho \"DEPLOY-ARGS $*\"\n")
      File.chmod(0o755, probe)
      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "repo_script", "command" => #{probe.inspect}, "args" => ["--yes"],
                                     "ci_verified_arg" => "--ci-verified" } })
      base = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(_s); end\n)

      green = run_cli(["--yes"], setup: base + %(ci_green_shas["sibling"] = #{frozen.inspect}\n),
                                 call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})
      assert_includes green, "DEPLOY-ARGS --yes --ci-verified=#{frozen}", green
      assert_includes green, "GitHub CI read GREEN"

      unread = run_cli(["--yes"], setup: base, call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})
      assert_includes unread, "DEPLOY-ARGS --yes\n", "no green read: the script runs its own suite"
      assert_includes unread, "its deploy runs its own suite"
    end
  end
end
