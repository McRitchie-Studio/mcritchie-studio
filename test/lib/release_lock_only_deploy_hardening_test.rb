require "minitest/autorun"
require "open3"

# Task lock-only-deploy-hardening (review notes 1-5 of lock-only-drop-follow-ups),
# on the REAL bin/release deploy, drop, prune and finalize functions. Heroku (its
# release list, the push, `heroku rollback`), the `/up` curl, `main` and the board
# are stubbed.
#   1  a lock-only app whose smoke stays red after its push is rolled back to the
#      Heroku release before it, and the drop says so; a failed release phase is
#      dropped with nothing to roll back.
#   2  a deploy that passed, then a failed `main` push, is recorded as live.
#   3  finalize does not record a lock-only app shipped while its `main` is behind.
#   4  the pre-publish lock check's drops leave the lists before the gate.
class ReleaseLockOnlyDeployHardeningTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # PUSH_STATUS: the status of the Heroku release a push makes. SMOKE_CODE: what /up
  # answers until a rollback lands. FAIL_MAIN: repos whose `main` push fails.
  STUB = <<~'RUBY'
    PUSH_STATUS = "succeeded" unless defined?(PUSH_STATUS)
    SMOKE_CODE = "200" unless defined?(SMOKE_CODE)
    FAIL_MAIN = [] unless defined?(FAIL_MAIN)
    $rel = [{ "version" => 10, "status" => "succeeded", "current" => true, "description" => "Deploy 0ld0ld0" }]
    $rolled = false
    def add_release(status, description)
      $rel.each { |r| r["current"] = false } if status == "succeeded"
      $rel << { "version" => $rel.map { |r| r["version"] }.max + 1, "status" => status,
                "current" => status == "succeeded", "description" => description }
    end
    def heroku_releases(_app, limit: 5) = $rel.sort_by { |r| -r["version"] }.first(limit).map(&:dup)
    def conductor(ruby, **)
      $stdout.puts("CONDUCTOR: #{ruby}")
      {}
    end
    def gate_sop(key, cmd, ok, *) = $stdout.puts("SOP: #{key} #{cmd} ok=#{ok}")
    def record_merged_main(*) = nil
    def record_deployed_apps(_rel, groups, _shas) = $stdout.puts("RECORDED_LIVE: #{groups.map { |g| g['repo'] }.join(',')}")
    def deploy_already_live?(*) = false
    def run_test_scope(*, **) = yield
    def sleep(*) = nil
    def push_frozen_main(repo, sha)
      abort!("push of #{repo} main was rejected") if FAIL_MAIN.include?(repo)
      $stdout.puts("PUSH_MAIN: #{repo}")
      ship_evidence[repo] = sha
    end
    def sh(*cmd, **)
      if cmd[0] == "git" && cmd.include?("push")
        $stdout.puts("HEROKU_PUSH: #{cmd[2].to_s.split('/').last}")
        add_release(PUSH_STATUS, "Deploy #{cmd[4].to_s[0, 7]}")
        return [nil, true]
      end
      if cmd[0] == "heroku" && cmd[1] == "rollback"
        $stdout.puts("HEROKU_ROLLBACK: #{cmd[2..].join(' ')}")
        add_release("succeeded", "Rollback to #{cmd[2]}")
        $rolled = true
        return [nil, true]
      end
      return [$rolled ? "200" : SMOKE_CODE, true] if cmd[0].to_s.end_with?("curl")

      ["", true]
    end
  RUBY

  HEROKU = %({ "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/rantly.git", ) +
           %("branch" => "main", "smoke_url" => "https://rantly.example" })
  GROUPS = %(app_groups = [{ "repo" => "mcritchie-studio", "kind" => "app" }, ) +
           %({ "repo" => "rantly", "kind" => "app", "lock_only" => true, "prod_deploy" => #{HEROKU} }]; ) +
           %(repos = app_groups.dup; )
  SHIP = %(deploy_apps(app_groups, { "rantly" => "abc1234ef", "mcritchie-studio" => "f00f00f" }, "rel-x"); ) +
         %(prune_lock_only!("rel-x", app_groups, repos); ) +
         %(puts("LEFT=" + app_groups.map { |g| g["repo"] }.join(",")); puts("CONTINUED"))

  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    env = { "RELEASE_LOCK_ONLY_RELEASE_POLLS" => "3", "RELEASE_LOCK_ONLY_RELEASE_POLL_DELAY" => "0" }
    out, = Open3.capture2e(env, RbConfig.ruby, "-e", script)
    out
  end

  # --- note 1: a red smoke after the push is rolled back ---

  def test_a_lock_only_smoke_that_stays_red_after_the_push_is_rolled_back_and_dropped
    out = run_release(%(SMOKE_CODE = "503"\n) + STUB, GROUPS + SHIP)

    assert_includes out, "HEROKU_PUSH: rantly", out
    assert_includes out, "HEROKU_ROLLBACK: v10 --app rantly", out
    assert_includes out, "SOP: rollback:rantly heroku rollback v10 --app rantly ok=true", out
    assert_includes out, "DROPPED rantly from this release — production deploy failed: smoke failed for rantly " \
                         "(https://rantly.example/up != 200); rolled back automatically to v10 on rantly", out
    assert_match(/LockOnlyConsumers\.drop\(r\.metadata \|\| \{\}, \{"rantly" ?=> ?"production deploy failed: smoke failed .*rolled back automatically to v10/, out)
    refute_includes out, "PUSH_MAIN: rantly", "`main` must not move for a dropped app: #{out}"
    assert_includes out, "LEFT=mcritchie-studio", out
    assert_includes out, "CONTINUED", out
  end

  def test_a_lock_only_smoke_that_recovers_in_the_boot_window_is_not_rolled_back
    stub = %(SMOKE_CODE = "503"\n) + STUB + <<~'RUBY'
      $curls = 0
      alias stub_sh sh
      def sh(*cmd, **kw)
        if cmd[0].to_s.end_with?("curl")
          $curls += 1
          return [$curls > 2 ? "200" : "503", true]
        end
        stub_sh(*cmd, **kw)
      end
    RUBY
    out = run_release(stub, GROUPS + SHIP)

    refute_includes out, "HEROKU_ROLLBACK", out
    assert_includes out, "PUSH_MAIN: rantly", out
    refute_includes out, "DROPPED", out
  end

  def test_a_failed_release_phase_drops_the_app_with_nothing_to_roll_back
    out = run_release(%(PUSH_STATUS = "failed"\n) + STUB, GROUPS + SHIP)

    assert_includes out, "DROPPED rantly from this release — production deploy failed: the Heroku release phase " \
                         "on rantly FAILED after the push; Heroku keeps v10", out
    refute_includes out, "HEROKU_ROLLBACK", out
    refute_includes out, "PUSH_MAIN: rantly", out
    assert_includes out, "CONTINUED", out
  end

  # The case the release-phase wait exists for: Heroku kept the OLD slug, which
  # still answers /up 200, so a smoke alone would pass and `main` would move.
  def test_a_failed_release_phase_is_caught_even_when_the_old_slug_answers_200
    out = run_release(%(PUSH_STATUS = "failed"\nSMOKE_CODE = "200"\n) + STUB, GROUPS + SHIP)

    assert_includes out, "release phase on rantly FAILED", out
    refute_includes out, "PUSH_MAIN: rantly", out
  end

  # The control: a MEMBER app's red smoke aborts the ship, as before, with no
  # rollback and no release-list read.
  def test_a_member_app_red_smoke_still_aborts_with_no_rollback
    groups = %(app_groups = [{ "repo" => "mcritchie-studio", "kind" => "app" }, ) +
             %({ "repo" => "rantly", "kind" => "app", "prod_deploy" => #{HEROKU} }]; repos = app_groups.dup; )
    out = run_release(%(SMOKE_CODE = "503"\n) + STUB, groups + SHIP)

    assert_includes out, "ABORTED: ✗ smoke failed for rantly", out
    refute_includes out, "HEROKU_ROLLBACK", out
    refute_includes out, "DROPPED", out
  end

  # --- note 2: the deploy passed, the `main` push failed ---

  def test_a_passed_deploy_whose_main_push_failed_is_recorded_as_live
    out = run_release(%(FAIL_MAIN = ["rantly"]\n) + STUB, GROUPS + SHIP)

    assert_includes out, "DROPPED rantly from this release — production deploy failed: its deploy passed and " \
                         "production runs abc1234, but its `main` push failed", out
    assert_includes out, "Its production deploy PASSED, so production runs abc1234, but its `main` did not move", out
    refute_includes out, "Its `main` did not move, so", "the not-shipped tail must not be used: #{out}"
    assert_match(/Release::Conductor\.record_deployed_apps\(release: r\.reload, deployed: \{"rantly" ?=> ?"abc1234ef"\}\)/, out)
    assert_includes out, "CONTINUED", out
  end

  # --- note 3: finalize ---

  FINALIZE = <<~'RUBY'
    MAIN = {} unless defined?(MAIN)
    def origin_main_sha(repo) = MAIN.fetch(repo, "")
    def git_capture(*args) = ["", args.include?("--is-ancestor") ? false : true]
  RUBY

  def finalize_call(live)
    %(groups = [{ "repo" => "turf-monster", "kind" => "app" }, ) +
      %({ "repo" => "rantly", "kind" => "app", "lock_only" => true }]; repos = groups.dup; ) +
      %(verdicts = { "turf-monster" => [true, ""], "rantly" => [#{live}, "no Deploy at the SHA"] }; ) +
      %(finalize_lock_only_drops!("rel-x", groups, repos, verdicts, { "turf-monster" => "t1", "rantly" => "abc1234ef" }); ) +
      %(puts("LEFT=" + groups.map { |g| g["repo"] }.join(",") + " REPOS=" + repos.map { |g| g["repo"] }.join(",")))
  end

  def test_finalize_drops_a_live_lock_only_app_whose_main_did_not_move
    out = run_release(%(MAIN = { "rantly" => "0ld0ld0ld" }\n) + STUB + FINALIZE, finalize_call(true))

    assert_includes out, "LEFT=turf-monster REPOS=turf-monster", out
    assert_includes out, "DROPPED rantly from this release — finalize: live at abc1234, but its `main` did not move", out
    assert_match(/record_deployed_apps\(release: r\.reload, deployed: \{"rantly" ?=> ?"abc1234ef"\}\)/, out)
  end

  def test_finalize_keeps_a_live_lock_only_app_whose_main_moved
    out = run_release(%(MAIN = { "rantly" => "abc1234ef" }\n) + STUB + FINALIZE, finalize_call(true))

    assert_includes out, "LEFT=turf-monster,rantly", out
    refute_includes out, "DROPPED", out
  end

  def test_finalize_drops_a_lock_only_app_it_cannot_prove_live_instead_of_refusing
    out = run_release(%(MAIN = { "rantly" => "0ld0ld0ld" }\n) + STUB + FINALIZE, finalize_call(false))

    assert_includes out, "LEFT=turf-monster", out
    assert_includes out, "DROPPED rantly from this release — finalize: not confirmed live at abc1234", out
    refute_includes out, "record_deployed_apps", out
  end

  # --- note 5: the sweep names the hub, so it never rides as lock-only ---

  def test_the_lock_only_sweep_excludes_the_hub
    assert_includes File.read(BIN), "held_repos: held_repos, hub: APP)",
                    "lock_only_consumer_repos must pass the hub to LockOnlyConsumers.candidates"
  end

  # --- note 4: the pre-publish lock check prunes before the gate ---

  def test_the_pre_publish_lock_check_drops_leave_the_lists_before_the_gate
    src = File.read(BIN)
    check = src.index("  refuse_stray_locks_before_publish!(app_groups, gem_plan)\n")
    gate = src.index("  pre_publish_gate(app_groups, gem_plan)\n")
    refute_nil check
    refute_nil gate
    assert_includes src[check...gate], "prune_lock_only!(rel_slug, app_groups, repos)",
                    "the lock check's drops must be pruned before the pre-publish gate reads the lists"
  end
end
