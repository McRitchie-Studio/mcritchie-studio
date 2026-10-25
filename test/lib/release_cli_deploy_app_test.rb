# frozen_string_literal: true

# deploy_app's production adapters and dispatch_and_watch.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_deploy_app_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliDeployAppTest < ReleaseCliHarness
  # --- deploy_app: what the deploy actually needs ------------------------------

  # [integration] git_push_heroku (industries, rolio) needs NO working tree: "deploy" is
  # handing a commit to a git remote. It ref-pushes the FROZEN SHA BY VALUE, which
  # is stricter than the old `git push heroku main` (that shipped whatever the local
  # branch pointed at, in a checkout any session could disturb). Proven on real git:
  # the "heroku" remote's main lands on the frozen SHA while the primary sits dirty
  # on a feature branch.
  def test_deploy_app_git_push_heroku_ref_pushes_the_frozen_sha_from_a_dirty_primary
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      heroku = File.join(dir, "heroku.git")
      system("git", "init", "--bare", "-q", heroku, out: File::NULL, err: File::NULL) || flunk("bare init failed")
      run_git(clone, "remote", "add", "heroku", heroku)
      frozen = git_out(clone, "rev-parse", "release")

      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "heroku", "branch" => "main" } })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(_s); end\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the deploy must not care that the primary is dirty: #{out}"
      assert_equal frozen, git_out(heroku, "rev-parse", "main"),
                   "the Heroku remote's main must be the FROZEN SHA — that is what boots in prod"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"),
                   "…and origin/main must have been advanced to it too"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out"
      assert_includes git_out(clone, "status", "--porcelain"), "app.rb", "…and its dirt survives"
    end
  end

  # [integration] repo_script (turf-monster) is the one adapter that DOES need a
  # working tree — its bin/deploy runs the repo's suite, hashes the IDL, and pushes
  # from the checkout it runs in. It gets the SHIP WORKSPACE, detached at the frozen
  # SHA. This test stands in for turf's bin/deploy and asserts the three things that
  # script actually depends on, rather than assuming them:
  #   * cwd is the ship workspace (NOT the primary, NOT the gate workspace),
  #   * `git rev-parse HEAD` there is the FROZEN SHA,
  #   * `git rev-parse --abbrev-ref HEAD` is the literal "HEAD" (detached) — which is
  #     what makes turf's own `PUSH_SPEC="$BRANCH:main"` resolve to `HEAD:main` and
  #     push exactly the frozen commit,
  #   * the tree is CLEAN, so its `git diff-index --quiet HEAD` preflight passes even
  #     while the primary is filthy.
  def test_deploy_app_repo_script_runs_in_the_ship_workspace_at_the_frozen_sha
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")
      probe  = File.join(dir, "probe.sh")
      File.write(probe, <<~SH)
        #!/usr/bin/env sh
        echo "DEPLOY-CWD $(pwd)"
        echo "DEPLOY-HEAD $(git rev-parse HEAD)"
        echo "DEPLOY-BRANCH $(git rev-parse --abbrev-ref HEAD)"
        git diff-index --quiet HEAD -- && echo "DEPLOY-TREE-CLEAN" || echo "DEPLOY-TREE-DIRTY"
      SH
      File.chmod(0o755, probe)

      # The primary is a live session's floor: off main, dirty.
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "repo_script", "command" => #{probe.inspect}, "args" => ["--yes"] } })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(_s); end\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the satellite deploy must survive a dirty primary: #{out}"
      assert_includes out, ".worktrees/_ship",
                      "the repo's deploy script must run in the SHIP workspace, not the primary or the gate's"
      assert_includes out, "DEPLOY-HEAD #{frozen}",
                      "…pinned at the QA-frozen SHA — the exact commit that ships"
      assert_includes out, "DEPLOY-BRANCH HEAD",
                      "…detached, which is what makes turf's PUSH_SPEC resolve to `HEAD:main` (the frozen commit)"
      assert_includes out, "DEPLOY-TREE-CLEAN",
                      "…and clean, so the repo's own clean-tree preflight passes while the primary is dirty"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"),
                   "the primary is never checked out by the satellite deploy"
    end
  end

  # [integration] NO prod_deploy — the 2026-08-22 wedge, from the other side.
  # chain-ops declared `command: bin/deploy` for a script that did not exist, so
  # ship ran it, it failed, and the WHOLE release aborted — after push_frozen_main
  # had already advanced origin/main. With the adapter dropped, deploy_app must
  # SKIP cleanly rather than crash on the nil: main still advances, members are
  # still stamped merged:"main", ship returns and carries on to the next app.
  #
  # It must also NOT say "deployed to production" — that lie is exactly what a
  # no-op bin/deploy would have bought, and it is the reason this path exists.
  def test_deploy_app_with_no_prod_deploy_advances_main_and_dispatches_nothing
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")

      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      # No "prod_deploy" key at all — a registered app with no production target.
      group = %({ "repo" => "sibling", "members" => [] })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(s); puts("STAMPED-MAIN \#{s.inspect}"); end\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED",
                      "an app with no deploy target must not abort the ship — that is the wedge: #{out}"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"),
                   "origin/main still advances — the ladder promotion is real even with nothing to deploy"
      assert_includes out, "STAMPED-MAIN",
                      "…and its members are still stamped merged:\"main\", so a re-run reads the ff as done"
      assert_includes out, "no production deploy target",
                      "the record must SAY there was nothing to dispatch"
      refute_match(/deployed to production/, out,
                   "it must never report a deploy that did not happen (the no-op bin/deploy lie)")
      refute_match(/unknown prod_deploy strategy/, out,
                   "a MISSING adapter is a case, not a misconfiguration — no strategy lookup should happen")
    end
  end

  # The other half of the line: a TYPO'd strategy must still abort. Reading it as
  # "nothing to deploy" would turn a misconfigured app into a silently-never-
  # deployed one — the same class of lie in the opposite direction.
  def test_deploy_app_still_aborts_on_an_unknown_strategy
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "rsync_box" } })
      # abort! exits, so the subprocess catches SystemExit and reports it on
      # stdout — run_cli flunks on a nonzero exit, and the ABORT is the assertion.
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(s); puts("STAMPED-MAIN \#{s.inspect}"); end\n)
      call  = %(begin; deploy_app(#{group}, #{frozen.inspect}); puts("PASSED"); rescue SystemExit; puts("ABORTED"); end)
      out = run_cli(["--yes"], setup: setup, call: call)

      refute_includes out, "PASSED", "a typo'd strategy must still stop the ship: #{out}"
      assert_includes out, "ABORTED", "…by aborting, not by treating the typo as \"nothing to deploy\""
      refute_includes out, "STAMPED-MAIN",
                      "…and it aborts BEFORE push_frozen_main — the wedge was aborting AFTER main moved"
    end
  end

  # [integration] github_actions (the hub, DevOps v2 Phase 2) deploys by dispatching
  # a workflow, not by pushing itself. push_frozen_main still ref-advances origin/main
  # (the workflow deploys the FROZEN SHA it is handed, not origin/main — which is why
  # prod-deploy.yml is workflow_dispatch, not push:[main]); then the conductor
  # dispatches prod-deploy.yml at the frozen SHA and watches it. The workflow owns the
  # Heroku push AND the hard /up smoke, so there is NO conductor curl-smoke here.
  # dispatch_and_watch is stubbed to capture the call without shelling out to real gh.
  def test_deploy_app_github_actions_dispatches_the_prod_workflow_at_the_frozen_sha
    Dir.mktmpdir do |dir|
      clone  = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")

      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "github_actions", "workflow" => "prod-deploy.yml" } })
      setup = <<~RUBY
        def repo_path(_repo) = #{clone.inspect}
        def record_merged_main(_s); end
        def dispatch_and_watch(workflow, inputs = {}, chdir: nil)
          puts("DISPATCH \#{workflow} sha=\#{inputs['sha']}")
          true
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{deploy_app(#{group}, #{frozen.inspect}); puts("PASSED")})

      assert_includes out, "PASSED", "the github_actions deploy must succeed: #{out}"
      assert_includes out, "DISPATCH prod-deploy.yml sha=#{frozen}",
                      "the hub deploy dispatches prod-deploy.yml at the FROZEN sha"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"),
                   "push_frozen_main still ref-advances origin/main to the frozen SHA before the dispatch"
      refute_includes out, "smoke: GET",
                      "no conductor curl-smoke for github_actions — the workflow owns the /up smoke"
    end
  end

  # [integration] dispatch_and_watch's run-id selection is the correctness core of
  # the github_actions deploy: `gh workflow run` names no run, so it snapshots the
  # newest run id BEFORE dispatch and watches the first STRICTLY-greater one. These
  # stub `sh` (+ no-op `sleep`) to drive that wiring without real gh; the pure truth
  # table lives in Release::ShipSequenceTest#new_run_id.
  def test_dispatch_and_watch_aborts_when_the_pre_dispatch_snapshot_never_answers
    # A `gh run list` FAILURE must NOT read as before_id=0 — that would let the poll
    # latch a PRE-EXISTING run and false-green a prod deploy. When the snapshot never
    # answers, dispatch_and_watch returns false AND never dispatches the workflow.
    setup = <<~RUBY
      def sleep(*) = nil
      $dispatched = false
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        return ["", false] if cmd[0, 3] == ["gh", "run", "list"]   # snapshot always fails
        $dispatched = true if cmd[0, 3] == ["gh", "workflow", "run"]
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{r = dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }); } +
                        %{puts("RESULT \#{r}"); puts("DISPATCHED \#{$dispatched}")})

    assert_includes out, "RESULT false", "a snapshot that never answers must ABORT, not watch a stale run"
    assert_includes out, "DISPATCHED false", "and must not even dispatch the workflow without a baseline"
  end

  def test_dispatch_and_watch_watches_the_strictly_greater_run_it_created
    # before_id snapshot = 100 (a prior run). After dispatch a NEW run 101 appears;
    # dispatch_and_watch must watch 101 (strictly greater), never the pre-existing 100.
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      $watched = nil
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]   # 1st = snapshot, then our new run
        end
        if cmd[0, 3] == ["gh", "run", "watch"]
          $watched = cmd[3]
          return ["", true]
        end
        ["", true]   # gh workflow run
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{r = dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }); } +
                        %{puts("RESULT \#{r} WATCHED \#{$watched}")})

    assert_includes out, "WATCHED 101", "must watch the strictly-greater run it created, not the pre-existing one"
    assert_includes out, "RESULT true", "a green watched run returns true"
  end

  def test_dispatch_and_watch_trusts_the_run_conclusion_when_the_watch_500s
    # The exact live scenario: watch dies, but `gh run view` reports completed/success.
    out = run_cli(["--yes"], setup: gha_watch_500_setup("completed\tsuccess"),
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT true",
                     "a watcher HTTP 500 must NOT abort a run that actually succeeded"
  end

  def test_dispatch_and_watch_fails_when_the_run_itself_concluded_failure
    out = run_cli(["--yes"], setup: gha_watch_500_setup("completed\tfailure"),
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT false",
                     "a genuinely failed run (watch failed AND conclusion=failure) fails closed"
  end

  # [integration] THE protection-pause regression (run 29450907913). A prod-deploy
  # run can sit in GitHub's `waiting` status — a deployment-protection gate holding
  # the deploy. (Historically this was the `production` Environment's required
  # reviewer, held `waiting` for as long as the operator took to click — 3h34m live —
  # before that approval was removed on 2026-07-20; a re-added protection rule would
  # produce it again.) If a transient blip kills `gh run watch` DURING that pause,
  # the fallback must HOLD on the still-live run — a `waiting`/`in_progress` read is
  # not a failed deploy — and only conclude when the run actually finishes. The old
  # fallback polled a 100s budget for `completed` and failed the ship CLOSED over a
  # run that was simply still live; this proves it now waits through the pause and
  # then succeeds. `sleep` is stubbed to a no-op so the "hold" costs no wall-clock.
  def test_dispatch_and_watch_holds_through_a_waiting_protection_pause_then_succeeds
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      # The run sits WAITING on a protection gate, moves to in_progress, then completes.
      $views = ["waiting\\t", "waiting\\t", "in_progress\\t", "completed\\tsuccess"]
      $view_i = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", false] if cmd[0, 3] == ["gh", "run", "watch"]   # transient blip mid-hold
        if cmd[0, 3] == ["gh", "run", "view"]
          v = $views[$view_i] || $views.last
          $view_i += 1
          return [v, true]
        end
        ["", true]   # gh workflow run
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "WAITING on a deployment protection gate",
                     "the fallback must RECOGNIZE the protection pause and hold, not fail closed on it"
    assert_includes out, "RESULT true",
                     "a run that was merely paused on a protection gate and then succeeded must ship"
  end

  # [integration] The stuck-timeout / never-appearing run — the fail-closed case
  # that SURVIVES the fix. `gh run view` can never read the run (it keeps erroring),
  # so there is no state to observe: after unreadable_limit consecutive unobserved
  # polls the fallback fails closed. This is distinct from an OBSERVABLE live run
  # (waiting/in_progress) which now holds — only a genuinely UNOBSERVABLE run gives
  # up. A redundant re-verify beats a false-green prod deploy.
  def test_dispatch_and_watch_fails_closed_when_the_run_is_unobservable
    setup = <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", false] if cmd[0, 3] == ["gh", "run", "watch"]
        return ["", false] if cmd[0, 3] == ["gh", "run", "view"]   # gh can NEVER read the run
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %{puts("RESULT " + dispatch_and_watch("prod-deploy.yml", { "sha" => "abc" }).to_s)})

    assert_includes out, "RESULT false",
                     "an unobservable run (gh can't read it at all) must fail closed, not hang or false-green"
    assert_includes out, "unobservable",
                     "…and say WHY it failed closed — the stuck-timeout, not a false conclusion"
  end

  # [unit] The env contract for a repo's OWN deploy script. It gets the workspace's
  # private test DB (so the suite it runs pre-prod can't be poisoned by a concurrent
  # one) and NOTHING else. Emphatically NOT the gate overlay: that sets
  # RAILS_ENV=test, which is right for a gate and WRONG for a production deploy
  # script — the next repo_script app could precompile assets in its deploy, and
  # doing that in the test env would build the wrong artifact and ship it.
  def test_ship_deploy_env_gives_the_script_a_private_db_and_never_rails_env_test
    Dir.mktmpdir do |dir|
      plant_database_yml(dir)
      setup = %(def repo_path(_repo) = #{dir.inspect})
      out = run_cli(["--yes"], setup: setup, call: %{print(ship_deploy_env("turf-monster").inspect)})

      env = eval(out) # rubocop:disable Security/Eval — the CLI printed its own Hash
      assert_equal "postgres:///turf_monster_ship_test", env["DATABASE_URL"],
                   "the script's suite must run on the ship workspace's PRIVATE DB"
      assert_nil env["RAILS_ENV"],
                 "a PRODUCTION deploy script must never inherit RAILS_ENV=test"
      assert_equal %w[DATABASE_URL], env.keys,
                   "exactly one var — the script's toolchain (PATH/ruby) is the script's business"
    end
  end

  # [unit] A SQLite app's test DB is a file INSIDE the workspace — already private.
  # Handing it a postgres URL would be a live trap, so the overlay is empty.
  def test_ship_deploy_env_is_empty_for_a_file_backed_test_db
    Dir.mktmpdir do |dir|
      plant_database_yml(dir, adapter: "sqlite3")
      setup = %(def repo_path(_repo) = #{dir.inspect})
      out = run_cli(["--yes"], setup: setup, call: %{print(ship_deploy_env("rolio").inspect)})

      assert_equal "{}", out, "a SQLite app needs no DB overlay — its test DB is already inside the workspace"
    end
  end
end
