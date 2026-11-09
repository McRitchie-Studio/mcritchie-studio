require "minitest/autorun"
require "open3"
require "tmpdir"

# Follow-ups to release-ships-lock-only-consumers (task lock-only-drop-follow-ups),
# on the REAL bin/release functions; git, the deploy and the board are stubbed.
#   F1  a lock-only app deploys BEFORE its `main` moves, so a failed deploy leaves
#       `main` behind and the next sweep carries it again.
#   F4  the re-pin and the stray, prerelease and unshipped-final checks drop a
#       lock-only app instead of aborting the release.
#   status / --expedite read a rung of lock bumps only as clean, and name it.
class ReleaseLockOnlyFollowUpsTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # FAIL_PUSH: repos whose Heroku push fails. Every `main` push prints PUSH_MAIN.
  STUB = <<~'RUBY'
    FAIL_PUSH = [] unless defined?(FAIL_PUSH)
    def conductor(ruby, **)
      $stdout.puts("CONDUCTOR: #{ruby}")
      {}
    end
    def gate_sop(*) = nil
    def record_merged_main(*) = nil
    def record_deployed_apps(*) = nil
    def deploy_already_live?(*) = false
    def push_frozen_main(repo, sha)
      $stdout.puts("PUSH_MAIN: #{repo}")
      ship_evidence[repo] = sha
    end
    def sh(*cmd, **)
      if cmd[0] == "git" && cmd.include?("push")
        repo = cmd[2].to_s.split("/").last
        $stdout.puts("HEROKU_PUSH: #{repo}")
        return [nil, !FAIL_PUSH.include?(repo)]
      end
      ["", true]
    end
  RUBY

  HEROKU = %({ "strategy" => "git_push_heroku", "remote" => "heroku" })

  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  # --- F1: deploy before main ---

  def test_a_lock_only_app_deploys_before_its_main_moves
    out = run_release(STUB, %(deploy_app({ "repo" => "rantly", "lock_only" => true, "prod_deploy" => #{HEROKU} }, "abc1234"); ) +
                            %(puts("DONE")))

    assert_includes out, "DONE", out
    assert_operator out.index("HEROKU_PUSH: rantly"), :<, out.index("PUSH_MAIN: rantly"), out
  end

  # The control: a member app still moves `main` first (its merged:"main" stamp
  # marks the ff before the deploy).
  def test_a_member_app_still_moves_main_first
    out = run_release(STUB, %(deploy_app({ "repo" => "turf-monster", "prod_deploy" => #{HEROKU} }, "abc1234"); puts("DONE")))

    assert_operator out.index("PUSH_MAIN: turf-monster"), :<, out.index("HEROKU_PUSH: turf-monster"), out
  end

  # The case F1 named: rantly's deploy fails at the production stage. Its `main`
  # never moves, the drop says so, and no `main` push is recorded as shipped.
  def test_a_failed_lock_only_deploy_leaves_main_where_it_was
    groups = %(app_groups = [{ "repo" => "mcritchie-studio", "kind" => "app", "prod_deploy" => #{HEROKU} }, ) +
             %({ "repo" => "rantly", "kind" => "app", "lock_only" => true, "prod_deploy" => #{HEROKU} }]; repos = app_groups.dup; )
    out = run_release(%(FAIL_PUSH = ["rantly"]\n) + STUB,
                      groups + %(deploy_apps(app_groups, { "mcritchie-studio" => "h1", "rantly" => "r1" }, "rel-x"); ) +
                      %(prune_lock_only!("rel-x", app_groups, repos); puts("EVIDENCE=" + ship_evidence.keys.join(",")); ) +
                      %(puts("LEFT=" + app_groups.map { |g| g["repo"] }.join(","))))

    refute_includes out, "PUSH_MAIN: rantly", out
    refute_includes out, "ABORTED", out
    assert_includes out, "EVIDENCE=mcritchie-studio\n", out
    assert_includes out, "LEFT=mcritchie-studio", out
    assert_includes out, "DROPPED rantly from this release — production deploy failed", out
    assert_includes out, "Its `main` did not move", out
  end

  # --- F4: the re-pin ---

  def test_a_failed_lock_only_repin_drops_it_and_the_member_still_repins
    stub = STUB + <<~'RUBY'
      def await_published_gems!(*) = nil
      def with_ship_workspace(_repo) = yield
      def ship_workspace!(repo, _sha)
        abort!("#{repo}: the ship workspace could not be pinned") if repo == "rantly"
        $stdout.puts("REPIN: #{repo}")
        "/nonexistent/#{repo}"
      end
      def git_capture(*) = ["", false]
    RUBY
    groups = %(app_groups = [{ "repo" => "turf-monster", "kind" => "app" }, ) +
             %({ "repo" => "rantly", "kind" => "app", "lock_only" => true }]; repos = app_groups.dup; )
    out = run_release(stub, groups + %(@ship_live = []; repin_consumers(app_groups, { "studio-engine" => "0.142.0" }, {}); ) +
                            %(prune_lock_only!("rel-x", app_groups, repos); puts("LEFT=" + app_groups.map { |g| g["repo"] }.join(",")); ) +
                            %(puts("CONTINUED")))

    # The member's own re-pin then aborts on the unreadable HEAD, exactly as before.
    assert_includes out, "REPIN: turf-monster", out
    assert_includes out, "ABORTED: ✗ could not read the ship workspace HEAD in turf-monster for re-pin", out

    only = run_release(stub, %(app_groups = [{ "repo" => "rantly", "kind" => "app", "lock_only" => true }]; repos = app_groups.dup; ) +
                             %(@ship_live = []; repin_consumers(app_groups, { "studio-engine" => "0.142.0" }, {}); ) +
                             %(prune_lock_only!("rel-x", app_groups, repos); puts("LEFT=" + app_groups.size.to_s); puts("CONTINUED")))

    assert_includes only, "CONTINUED", only
    refute_includes only, "ABORTED", only
    assert_includes only, "DROPPED rantly from this release — re-pin failed: rantly: the ship workspace could not be pinned", only
    assert_includes only, "LEFT=0", only
  end

  # --- F4: the stray, prerelease and unshipped-final checks ---

  FINDINGS = <<~'RUBY'
    def stray_candidate_findings(groups, *, **)
      groups.filter_map { |g| "#{g['repo']} locks studio-engine 0.142.0.rc1 at abc" if %w[rantly turf-monster].include?(g["repo"]) && STRAY.include?(g["repo"]) }
    end
    def unshipped_final_findings(*, **) = []
  RUBY

  def test_a_prerelease_in_a_lock_only_tree_drops_it_instead_of_refusing_the_deploy
    out = run_release(%(STRAY = ["rantly"]\n) + STUB + FINDINGS,
                      %(g = [{ "repo" => "turf-monster", "kind" => "app" }, { "repo" => "rantly", "kind" => "app", "lock_only" => true }]; ) +
                      %(refuse_prerelease_deploy!(g, {}); refuse_unshipped_final_deploy!(g, {}, {}); puts("CONTINUED")))

    assert_includes out, "CONTINUED", out
    assert_includes out, "DROPPED rantly from this release — prerelease check before the deploy: rantly locks studio-engine 0.142.0.rc1", out
  end

  def test_a_prerelease_in_a_member_tree_still_refuses_the_deploy
    out = run_release(%(STRAY = ["turf-monster", "rantly"]\n) + STUB + FINDINGS,
                      %(g = [{ "repo" => "turf-monster", "kind" => "app" }, { "repo" => "rantly", "kind" => "app", "lock_only" => true }]; ) +
                      %(refuse_prerelease_deploy!(g, {}); puts("CONTINUED")))

    assert_includes out, "ABORTED: ✗ REFUSING TO DEPLOY a prerelease gem — turf-monster locks", out
    refute_match(/REFUSING TO DEPLOY a prerelease gem — [^\n]*rantly/, out)
  end

  def test_a_stray_candidate_after_the_bump_drops_a_lock_only_app
    out = run_release(%(STRAY = ["rantly"]\n) + STUB + FINDINGS,
                      %(g = [{ "repo" => "turf-monster", "kind" => "app" }, { "repo" => "rantly", "kind" => "app", "lock_only" => true }]; ) +
                      %(refuse_stray_candidates!(g, {}); puts("CONTINUED")))

    assert_includes out, "CONTINUED", out
    assert_includes out, "DROPPED rantly from this release — lock check after the bump", out
  end

  # --- status / --expedite: a rung of lock bumps only ---

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise out unless status.success?

    out
  end

  def with_repo
    Dir.mktmpdir("lock-only-rung") do |dir|
      git(dir, "init", "-q", "-b", "main")
      git(dir, "config", "user.email", "t@example.com")
      git(dir, "config", "user.name", "T")
      File.write(File.join(dir, "Gemfile.lock"), "studio-engine (0.141.0)\n")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "base")
      git(dir, "branch", "base")
      File.write(File.join(dir, "Gemfile.lock"), "studio-engine (0.141.1)\n")
      git(dir, "commit", "-qam", "bump studio-engine 0.141.1")
      yield dir
    end
  end

  def test_a_rung_of_lock_bumps_only_counts_clean_and_is_named
    with_repo do |dir|
      out = run_release(STUB.sub(/def sh\(.*?\n    end\n/m, ""),
                        %(found = []; n = lock_only_rung(#{dir.inspect}, "rantly", "accepted", "base", "main", 1, found); ) +
                        %(puts("N=" + n.to_s); puts("FOUND=" + found.inspect); ) +
                        %(drops = [{ "slug" => "rel-x", "dropped" => { "alex-build" => "production deploy failed: smoke" } }]; ) +
                        %(lock_only_status_report({ "lock_only_rungs" => found, "lock_only_dropped" => drops })))

      assert_includes out, "N=0", out
      assert_includes out, %(rantly: `accepted` carries 1 lock bump commit(s) only), out
      assert_includes out, "DROPPED alex-build from rel-x: production deploy failed: smoke", out
    end
  end

  def test_a_rung_with_any_other_commit_keeps_its_count
    with_repo do |dir|
      File.write(File.join(dir, "app.rb"), "x\n")
      git(dir, "add", ".")
      git(dir, "commit", "-qm", "a human change")
      out = run_release(STUB.sub(/def sh\(.*?\n    end\n/m, ""),
                        %(found = []; n = lock_only_rung(#{dir.inspect}, "rantly", "accepted", "base", "main", 2, found); ) +
                        %(puts("N=" + n.to_s); puts("FOUND=" + found.size.to_s)))

      assert_includes out, "N=2", out
      assert_includes out, "FOUND=0", out
    end
  end
end
