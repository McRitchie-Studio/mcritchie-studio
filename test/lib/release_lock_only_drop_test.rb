require "minitest/autorun"
require "open3"

# A lock-only app (Release::LockOnlyConsumers) rides for nobody's card, so a failure
# of its OWN drops it from the release and the member apps still ship (review of
# release-ships-lock-only-consumers, 2026-11-09: rantly's Eco dyno 503s in the last
# week of each month, and one red smoke would have stopped every member). The REAL
# bin/release gate, deploy and prune functions; the CI read, the deploy itself and
# the board stubbed.
class ReleaseLockOnlyDropTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # RED: repos whose CI read is red. FAIL_DEPLOY: repos whose production deploy or
  # smoke aborts. Every board write prints CONDUCTOR: <ruby>.
  STUB = <<~'RUBY'
    RED = [] unless defined?(RED)
    FAIL_DEPLOY = [] unless defined?(FAIL_DEPLOY)
    def conductor(ruby, **)
      $stdout.puts("CONDUCTOR: #{ruby}")
      {}
    end
    def release_app_ci_verdict(repo, label:)
      { repo: repo, sha: "abc1234def", cmd: "bin/rails test", budget: 1,
        verdict: { credited: false }, ci: { state: RED.include?(repo) ? :red : :green } }
    end
    def ci_pass?(ci) = ci[:state] == :green
    def pre_qa_ci_abort(repo, *, **) = "#{repo} CI is RED"
    def gate_sop(*) = nil
    def tree_verdict_sop(*) = "sop"
    def record_qa_gate(*) = nil
    def test_gate(repo, **)
      abort!("ship gate #{repo}: CI RED") if RED.include?(repo)
      $stdout.puts("GATED: #{repo}")
    end
    def deploy_app(group, _sha)
      abort!("#{group['repo']}: smoke /up answered 503") if FAIL_DEPLOY.include?(group["repo"])
      $stdout.puts("DEPLOYED: #{group['repo']}")
    end
    def record_deployed_apps(*) = nil
  RUBY

  GROUPS = %(app_groups = [{ "repo" => "mcritchie-studio", "kind" => "app" }, ) +
           %({ "repo" => "turf-monster", "kind" => "app" }, ) +
           %({ "repo" => "rantly", "kind" => "app", "lock_only" => true }]; ) +
           %(repos = app_groups.dup; )
  LEFT = %(puts("LEFT=" + app_groups.map { |g| g["repo"] }.join(",") + " REPOS=" + repos.map { |g| g["repo"] }.join(",")); ) +
         %(puts("CONTINUED"))

  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def test_a_red_pre_qa_gate_drops_the_lock_only_app_and_the_release_carries_on
    out = run_release(%(RED = ["rantly"]\n) + STUB,
                      GROUPS + %(pre_qa_gate(app_groups, "rel-x"); prune_lock_only!("rel-x", app_groups, repos); ) + LEFT)

    assert_includes out, "CONTINUED", out
    assert_includes out, "LEFT=mcritchie-studio,turf-monster REPOS=mcritchie-studio,turf-monster", out
    assert_includes out, "⚠ DROPPED rantly from this release — pre-QA gate failed: rantly CI is RED", out
    assert_match(/LockOnlyConsumers\.drop\(r\.metadata \|\| \{\}, \{"rantly" ?=> ?"pre-QA gate failed: rantly CI is RED"\}\)/, out)
    assert_includes out, %(Release.find_by!(slug: "rel-x")), "the drop is recorded on this release: #{out}"
  end

  # The control: a MEMBER app's red still stops the release, exactly as before.
  def test_a_red_member_app_still_aborts_the_gate
    out = run_release(%(RED = ["turf-monster"]\n) + STUB, GROUPS + %(pre_qa_gate(app_groups, "rel-x"); ) + LEFT)

    assert_includes out, "ABORTED: ✗ turf-monster CI is RED", out
    refute_includes out, "DROPPED", out
  end

  def test_a_red_pre_publish_gate_drops_the_lock_only_app
    out = run_release(%(RED = ["rantly"]\n) + STUB,
                      GROUPS + %(pre_publish_gate(app_groups, [{ "repo" => "studio-engine" }]); ) +
                      %(prune_lock_only!("rel-x", app_groups, repos); ) + LEFT)

    assert_includes out, "LEFT=mcritchie-studio,turf-monster", out
    assert_includes out, "DROPPED rantly from this release — pre-publish gate failed", out
  end

  def test_a_red_ship_gate_drops_the_lock_only_app_and_the_member_still_gates
    out = run_release(%(RED = ["rantly"]\n) + STUB,
                      GROUPS + %(run_ship_gate(app_groups, {}); prune_lock_only!("rel-x", app_groups, repos); ) + LEFT)

    assert_includes out, "GATED: turf-monster", out
    assert_includes out, "LEFT=mcritchie-studio,turf-monster", out
    assert_includes out, "DROPPED rantly from this release — ship gate failed", out
  end

  # The case the review named: rantly's smoke fails while the satellites deploy
  # concurrently. turf-monster still goes live, and the ship does not abort.
  def test_a_failed_lock_only_smoke_is_dropped_and_the_member_app_still_ships
    out = run_release(%(FAIL_DEPLOY = ["rantly"]\n) + STUB,
                      GROUPS + %(deploy_apps(app_groups, {}, "rel-x"); prune_lock_only!("rel-x", app_groups, repos); ) + LEFT)

    assert_includes out, "DEPLOYED: mcritchie-studio", out
    assert_includes out, "DEPLOYED: turf-monster", out
    assert_includes out, "CONTINUED", "a lock-only failure must not abort the ship: #{out}"
    refute_includes out, "ABORTED", out
    assert_includes out, "DROPPED rantly from this release — production deploy failed", out
    assert_includes out, "LEFT=mcritchie-studio,turf-monster", out
  end

  # The control: a member satellite's failed deploy still aborts the ship.
  def test_a_failed_member_deploy_still_aborts_the_ship
    out = run_release(%(FAIL_DEPLOY = ["turf-monster"]\n) + STUB, GROUPS + %(deploy_apps(app_groups, {}, "rel-x"); ) + LEFT)

    assert_match(/ABORTED: .*satellite deploy.*FAILED \(turf-monster\)/m, out)
  end

  # One satellite runs inline, not on a thread: the same drop applies.
  def test_a_lone_lock_only_satellite_failure_is_dropped
    groups = %(app_groups = [{ "repo" => "mcritchie-studio", "kind" => "app" }, ) +
             %({ "repo" => "rantly", "kind" => "app", "lock_only" => true }]; repos = app_groups.dup; )
    out = run_release(%(FAIL_DEPLOY = ["rantly"]\n) + STUB,
                      groups + %(deploy_apps(app_groups, {}, "rel-x"); prune_lock_only!("rel-x", app_groups, repos); ) + LEFT)

    assert_includes out, "DEPLOYED: mcritchie-studio", out
    assert_includes out, "LEFT=mcritchie-studio REPOS=mcritchie-studio", out
    refute_includes out, "ABORTED", out
  end

  # QA: a lock-only app whose QA does not boot is dropped; the member's QA verdict
  # is its own, and nothing aborts.
  def test_a_lock_only_qa_that_does_not_boot_is_dropped
    stub = STUB + <<~'RUBY'
      def record_release_event(*) = nil
      def qa_deploy_app!(group, **)
        ok = group["repo"] != "rantly"
        { "repo" => group["repo"], "qa_app" => group["repo"], "qa_url" => "https://qa.#{group['repo']}", "sha" => "s", "ok" => ok }
      end
    RUBY
    call = %(qa = [{ "repo" => "mcritchie-studio", "kind" => "app" }, { "repo" => "rantly", "kind" => "app", "lock_only" => true }]; ) +
           %(o = run_qa_deploys(qa, "rel-x", repos: qa, qa_shas: {}, skip_gauntlet: true); ) +
           %(puts("QA=" + o[:deployed].map { |d| d["repo"] + ":" + d["ok"].to_s }.join(",")); puts("CONTINUED"))
    out = run_release(stub, call)

    assert_includes out, "QA=mcritchie-studio:true", out
    assert_includes out, "DROPPED rantly from this release — QA did not boot", out
    assert_includes out, "CONTINUED", out
  end

  # The operator's hand drop.
  def test_drop_lock_only_takes_a_carried_repo_out_of_the_current_release
    stub = STUB + <<~'RUBY'
      def conductor(ruby, **)
        $stdout.puts("CONDUCTOR: #{ruby}")
        ruby.include?("recorded(") ? { "slug" => "rel-now", "lock_only" => %w[rantly commercial-welding] } : {}
      end
    RUBY
    out = run_release(stub, %(ARGV.replace(["rantly", "--reason", "Eco quota"]); drop_lock_only))

    assert_match(/LockOnlyConsumers\.drop\(r\.metadata \|\| \{\}, \{"rantly" ?=> ?"Eco quota"\}\)/, out)
    assert_includes out, "✓ rantly is out of rel-now", out
  end

  def test_drop_lock_only_refuses_a_repo_the_release_does_not_carry_as_lock_only
    stub = STUB + <<~'RUBY'
      def conductor(ruby, **)
        $stdout.puts("CONDUCTOR: #{ruby}")
        ruby.include?("recorded(") ? { "slug" => "rel-now", "lock_only" => %w[rantly] } : {}
      end
    RUBY
    out = run_release(stub, %(ARGV.replace(["turf-monster"]); drop_lock_only))

    assert_includes out, "ABORTED: ✗ rel-now does not carry turf-monster as a lock-only app", out
    refute_includes out, "LockOnlyConsumers.drop", out
  end
end
