# frozen_string_literal: true

# post_deploy_cmd on QA and production, the agent-docs sync after a ship, and the
# QA smoke records that ride the post-deploy hook.
#
# Part of the bin/release CLI suite, split by subcommand from the old
# test/lib/release_cli_test.rb (release-cli-tests-by-subcommand, 2026-10-05). The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_post_deploy_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliPostDeployTest < ReleaseCliHarness
  def test_prepare_dry_run_prints_the_post_deploy_command_on_the_qa_app
    out = run_cli(["--dry-run"], call: "prepare", setup: POST_DEPLOY_PREP_STUB)

    assert_includes out, "post-deploy hooks (QA)"
    # The printed command is byte-for-byte what executes: `--exit-code` (so heroku
    # passes through the remote exit status — the abort-on-failure linchpin) and the
    # `--` flag-terminator before the task-declared command.
    assert_includes out, "heroku run -a turf-monster-qa --no-tty --exit-code -- rake pokemon:backfill_mascots",
                     "prepare runs the post-deploy command on the QA heroku app with --exit-code"
  end
  def test_prepare_reaches_assemble_with_a_paren_post_deploy_cmd
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB)

    refute_includes out, "UNSAFE-PAYLOAD",
                     "every conductor snippet (incl. the paren/quote post_deploy_cmd record) rides shell-safe"
    assert_includes out, "post-deploy hooks (QA)", "the QA post-deploy hook ran for the paren cmd"
    assert_includes out, "ASSEMBLE-REACHED",
                     "prepare reaches Release::Conductor.assemble! even with a paren/quote post_deploy_cmd"
    assert_includes out, "Assembled rel-paren", "the release assembles cleanly"
  end

  def test_prepare_dry_run_has_no_post_deploy_hook_when_no_member_declares_one
    # STUB_CONDUCTOR's members carry no post_deploy_cmd — the hook is opt-in.
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    refute_includes out, "post-deploy hooks", "no member declares a command → no hook runs"
  end
  def test_ship_dry_run_prints_the_post_deploy_command_on_the_prod_app
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    assert_includes out, "post-deploy hooks (prod)"
    assert_includes out, "heroku run -a turf-monster-mainnet --no-tty --exit-code -- rake pokemon:backfill_mascots",
                     "ship runs the post-deploy command on the production app with --exit-code"
  end

  def test_ship_dry_run_runs_post_deploy_after_the_app_deploys
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)
    deploy_at = out.index("bin/deploy --yes")     # the app's prod deploy
    hook_at   = out.index("post-deploy hooks")    # the post-deploy hook
    assert deploy_at && hook_at, "both the deploy and the hook must appear"
    assert_operator deploy_at, :<, hook_at, "the post-deploy hook runs AFTER the app deploys + smokes"
  end

  # --- post-ship agent-docs sync (the OWNED bin/install-agent-docs run) -------
  # Ship's step 7b runs bin/install-agent-docs AFTER the ship record + restored
  # primaries — post-SHIP, not post-merge, because the installer reads the LOCAL
  # hub checkout's docs and only then does the primary's `main` hold exactly what
  # shipped. NON-FATAL by construction: a docs sync must never abort a ship.

  def test_ship_dry_run_syncs_agent_docs_after_the_shipped_banner
    out = run_cli(["--dry-run"], call: "ship", setup: POST_DEPLOY_SHIP_STUB)

    shipped_at = out.index("Shipped rel-pd-ship")
    sync_at    = out.index("sync installed agent docs")
    assert shipped_at && sync_at, "both the shipped banner and the docs-sync step must appear"
    assert_operator shipped_at, :<, sync_at,
                    "the docs sync runs POST-ship (after the shipped record), never before"
    assert_includes out, "install-agent-docs", "the dry run prints the installer command"
  end

  # sync_agent_docs installs from the hub's SHIP WORKSPACE (the tree pinned at the
  # SHA that just shipped), falling back to the primary only when no such workspace
  # exists — see the method's comment. The branch is chosen by whether
  # `<ship-workspace>/bin/install-agent-docs` exists, and GateWorkspace.path is an
  # ABSOLUTE path, so a raw run's outcome depends on the HOST filesystem: CI (no
  # _ship) always hit the primary; a gate box that had materialized _ship hit the
  # ship-workspace branch. The old single test asserted the primary path + refuted
  # ".worktrees", so it FAILED on any host with a _ship workspace (env-divergence,
  # not a regression). These two stub GateWorkspace.path to fix the branch on every
  # host and assert the DESIGN: ship-workspace preferred, primary fallback.

  def test_sync_agent_docs_installs_from_the_shipped_ship_workspace
    setup = <<~RUBY
      require "tmpdir"; require "fileutils"
      WS = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(WS, "bin"))
      File.write(File.join(WS, "bin", "install-agent-docs"), "")
      Release::GateWorkspace.define_singleton_method(:path) { |*_| WS }
      $stdout.puts("WS " + WS)
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["installed-docs-output", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs")

    ws   = out[/^WS (.+)$/, 1]
    argv = out[/SH-ARGV (.*)/, 1].to_s
    assert ws, "sanity: the stub reported its ship-workspace path"
    assert_includes argv, File.join(ws, "bin", "install-agent-docs"),
                    "the sync shells the SHIP WORKSPACE's installer (the just-shipped tree), preferring it over the primary"
    assert_includes out, "installed-docs-output", "the installer's output is surfaced to the operator"
  end

  def test_sync_agent_docs_falls_back_to_the_primary_without_a_ship_workspace
    setup = <<~RUBY
      Release::GateWorkspace.define_singleton_method(:path) { |*_| "/no/such/ship/_ship" }
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["installed-docs-output", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs")

    argv = out[/SH-ARGV (.*)/, 1].to_s
    assert_includes argv, "bin/install-agent-docs", "the fallback still shells the hub's installer"
    refute_includes argv, "/no/such/ship/_ship", "a MISSING ship workspace must not be used — fall back to the primary"
    assert_includes out, "installed-docs-output", "the installer's output is surfaced"
  end

  def test_sync_agent_docs_failure_never_aborts_the_ship
    setup = <<~RUBY
      def sh(*_a, **_k) = ["boom", false]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs; puts('SHIP-CONTINUES')")

    assert_includes out, "agent-docs install failed", "a failed install warns with the by-hand fix"
    assert_includes out, "SHIP-CONTINUES", "a docs-sync failure never aborts the completed ship"
  end

  def test_sync_agent_docs_exception_never_aborts_the_ship
    setup = <<~RUBY
      def sh(*_a, **_k) = raise("no such installer")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs; puts('SHIP-CONTINUES')")

    assert_includes out, "agent-docs install skipped (no such installer)",
                     "an installer exception is rescued and reported with the by-hand fix"
    assert_includes out, "SHIP-CONTINUES", "an installer exception never aborts the completed ship"
  end

  def test_sync_agent_docs_rescue_names_an_absolute_installer_after_resolution
    setup = <<~RUBY
      def sh(*_a, **_k) = raise("no such installer")
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs")

    assert_absolute_installer(skipped_installer_path(out), out, when_: "sh raised, path already resolved")
  end

  def test_sync_agent_docs_rescue_names_an_absolute_installer_before_resolution
    # GateWorkspace.path raises on the FIRST line of the body, so the rescue fires with
    # `installer` still nil. `sh` is stubbed only as a tripwire — it must never be reached.
    setup = <<~RUBY
      Release::GateWorkspace.define_singleton_method(:path) { |*_| raise("workspace lookup exploded") }
      def sh(*a, **_k)
        $stdout.puts("SH-REACHED " + a.inspect)
        ["", true]
      end
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "sync_agent_docs; puts('SHIP-CONTINUES')")

    assert_includes out, "agent-docs install skipped (workspace lookup exploded)",
                    "sanity: the rescue fired on the workspace lookup, not somewhere later"
    refute_includes out, "SH-REACHED",
                    "sanity: the raise must precede the `sh` call, or this case is not testing the " \
                    "unresolved-path branch at all"
    assert_absolute_installer(skipped_installer_path(out), out, when_: "raised before the path resolved")
    assert_includes out, "SHIP-CONTINUES",
                    "a raise before the path resolves must still be non-fatal to the completed ship"
  end

  # A non-zero exit from `heroku run` must ABORT the pipeline. Drive run_post_deploy
  # directly (DRY=false) with `sh` stubbed to FAIL — but the stub first ECHOES its
  # argv, so we also prove the EXECUTED command carries `--exit-code` (the flag that
  # makes heroku passthrough the remote exit status; without it heroku returns 0 at
  # dyno launch and abort-on-failure never fires). `conductor` (record write) is a
  # no-op. Keeps the stubbed-false branch for abort coverage without a real dyno.
  def test_post_deploy_aborts_the_pipeline_on_a_nonzero_exit
    setup = <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)  # echo the executed heroku argv...
        ["the command exploded", false]        # ...then fail (non-zero remote exit)
      end
      def conductor(*_a, **_k) = {}             # record write is a no-op
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake boom" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; run_post_deploy(REPOS, target: :qa); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, %q("--exit-code"),
                     "the EXECUTED heroku argv passes --exit-code so a failing remote command returns non-zero"
    assert_includes out, %q("turf-monster-qa"), "it attempted the command on the QA app"
    assert_includes out, "ABORTED", "a non-zero post-deploy exit aborts the pipeline"
  end
  def test_post_deploy_shell_splits_and_terminates_heroku_flags
    setup = POST_DEPLOY_ARGV_STUB + <<~RUBY
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf",
                                 "post_deploy_cmd" => %q(rake "db:migrate[hello world]") }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "run_post_deploy(REPOS, target: :qa)")

    assert_includes out, %q("--"),
                     "a `--` terminator stops heroku flag parsing before the task command"
    assert_includes out, %q("db:migrate[hello world]"),
                     "Shellwords keeps a quoted/spaced arg as a single token (not two argv entries)"
  end

  # A declared post_deploy_cmd on a repo with no resolvable target app (a gem, or
  # an app missing from qa_environments.yml) is a HARD abort — never a silent no-op.
  def test_post_deploy_aborts_when_a_declared_command_has_no_target_app
    setup = <<~RUBY
      def conductor(*_a, **_k) = {}
      REPOS = [{ "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
                 "members" => [{ "slug" => "t-gem", "post_deploy_cmd" => "rake noop" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; run_post_deploy(REPOS, target: :prod); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ABORTED", "an unroutable declared command aborts rather than silently skipping"
  end
  def test_cyvasse_qa_post_deploy_is_skipped_by_its_declared_exemption
    out = run_cli(["--yes"], setup: POST_DEPLOY_ARGV_STUB + CYVASSE_POST_DEPLOY_REPOS,
                  call: "begin; run_post_deploy(REPOS, target: :qa); puts('QA-CONTINUES'); " \
                        "rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "SKIPPED at QA", "the skip is printed, not silent"
    assert_includes out, "qa_evidence: exempt", "the printed line names the exemption"
    refute_includes out, "SH-ARGV", "nothing runs on a QA app that does not exist"
    refute_includes out, "ABORTED"
    assert_includes out, "QA-CONTINUES", "prepare carries on to the QA-green stamp"
  end

  def test_cyvasse_prod_post_deploy_runs_on_the_app_its_prod_deploy_names
    out = run_cli(["--yes"], setup: POST_DEPLOY_ARGV_STUB + CYVASSE_POST_DEPLOY_REPOS,
                  call: "begin; run_post_deploy(REPOS, target: :prod); rescue SystemExit; puts('ABORTED'); end")

    refute_includes out, "ABORTED", "ship must not abort after the push is live"
    assert_includes out, %q("-a", "cyvasse"), "the command runs on Heroku app cyvasse"
    assert_includes out, %q("users:seed_identities")
  end

  # The fence: a NON-exempt app with no QA env entry keeps the hard abort at QA.
  def test_post_deploy_still_aborts_for_a_non_exempt_app_with_no_qa_env
    setup = <<~RUBY
      def conductor(*_a, **_k) = {}
      REPOS = [{ "repo" => "chain-ops", "kind" => "app", "qa_app" => "chain-ops",
                 "members" => [{ "slug" => "t-chain", "post_deploy_cmd" => "rake noop" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; run_post_deploy(REPOS, target: :qa); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "ABORTED"
    refute_includes out, "SKIPPED at QA"
  end

  # [integration] A REAL release gate (run_post_deploy) runs its command THROUGH
  # run_test_scope end-to-end: the hardened heroku argv still executes, and the
  # scope telemetry is emitted into the open span with the target-derived key.
  def test_post_deploy_runs_through_the_telemetry_wrapper_end_to_end
    setup = SCOPE_EMIT_STUB + <<~RUBY
      def sh(*a, **_k)
        $stdout.puts("SH-ARGV " + a.inspect)
        ["1 runs, 1 assertions, 0 failures, 0 errors", true]
      end
      def conductor(*_a, **_k) = {}
      REPOS = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
                 "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake db:migrate" }] }]
    RUBY
    out = run_cli(["--yes"], setup: setup, call: "run_post_deploy(REPOS, target: :qa); print($events.inspect)")

    assert_includes out, "SH-ARGV", "the gate's heroku command still executes through the wrapper"
    assert_includes out, %q("--exit-code"), "…with its argv hardening intact"
    assert_includes out, "test scope qa_post_deploy START", "the QA post-deploy runs as a telemetered scope"
    assert_includes out, "test scope qa_post_deploy COMPLETED", "…emitting a COMPLETED action end-to-end"
  end

  def test_prepare_records_qa_smoke_completed_only_after_the_post_deploy_hook_passes
    out = run_cli(["--yes"], setup: SWEEP_FLOW_STUB + RRE_ECHO, call: "prepare")

    assert_includes out, "RRE qa_smoke started", "the QA smoke opens at the first QA deploy"
    assert_includes out, "RRE qa_smoke completed", "…and closes green once QA booted + post-deploy passed"
    refute_includes out, "RRE qa_smoke failed", "a green run never records a failed stamp"
    started_at   = out.index("RRE qa_smoke started")
    completed_at = out.index("RRE qa_smoke completed")
    assert_operator started_at, :<, completed_at, "completed lands after started"
  end

  def test_prepare_does_not_record_qa_smoke_completed_when_the_post_deploy_hook_aborts
    # A blocking QA post-deploy hook that aborts must leave qa_smoke NOT green —
    # the premature-green bug: the stamp used to land before this hook ran.
    setup = SWEEP_FLOW_STUB + RRE_ECHO + %(\ndef run_post_deploy(*_a, **_k); abort!("post-deploy boom"); end)
    out = run_cli(["--yes"], setup: setup,
                  call: %(begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end))

    assert_includes out, "RRE qa_smoke started", "the smoke still opens at the QA deploy"
    assert_includes out, "ABORTED", "the blocking post-deploy hook aborts prepare"
    refute_includes out, "RRE qa_smoke completed",
                     "qa_smoke must NOT be stamped completed when the blocking post-deploy hook aborts"
    refute_includes out, "NO-ABORT"
  end

  def test_prepare_records_qa_smoke_failed_on_a_boot_failure
    setup = SWEEP_FLOW_STUB + RRE_ECHO + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], setup: setup, call: "prepare")

    assert_includes out, "RRE qa_smoke started", "the smoke opens at the QA deploy"
    assert_includes out, "RRE qa_smoke failed", "a boot failure closes the smoke as failed"
    refute_includes out, "RRE qa_smoke completed", "a boot failure never records a completed stamp"
  end
end
