# frozen_string_literal: true

# `bin/release ship`: the ship gate, --skip-test-gate, the dry-run plan, the Steffon
# E2E gate, gem publish at ship, and the ship preflight.
#
# Part of the bin/release CLI suite, split by subcommand from the old
# test/lib/release_cli_test.rb (release-cli-tests-by-subcommand, 2026-10-05). The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_ship_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliShipTest < ReleaseCliHarness
  # [unit] The ship gate now mutates NOTHING. It used to fast-forward each app's
  # `main` in the primary (under the primary lock) before running the suite — but
  # the suite moved to the isolated gate workspace at the frozen SHA, so that ff fed
  # nothing and only flipped a shared checkout. With it gone, a red gate or a
  # declined ship-authority confirm leaves the machine exactly as it found it.
  def test_run_ship_gate_mutates_nothing_before_ship_authority
    Dir.mktmpdir do |dir|
      setup = %(ENV["RELEASE_CI_STATUS"] = "green"\n) +
              %(def repo_path(_repo) = #{dir.inspect}\n) + GATE_GIT_STUB + <<~'RUBY'
        def app_meta_for(_repo) = { "test_cmd" => "bin/ship-suite" }
        def with_primary_checkout(repo, wait: true)
          $stdout.puts("PRIMARY-LOCK-TAKEN #{repo}")
          yield
        end
        def sh(*a, **k)
          # Writes to the PRIMARY are what must not happen. The gate workspace's own
          # git (worktree/reset/clean, keyed on a[3]) is answered by gate_git below.
          $stdout.puts("PRIMARY-WRITE #{a[3]}") if a[0] == "git" && %w[checkout pull merge push].include?(a[3].to_s)
          $stdout.puts("SUITE") if a[0] == "bin/ship-suite"
          g = gate_git(a, k)
          return g if g
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %{run_ship_gate([{ "repo" => "x" }], { "x" => #{GATE_SHA.inspect} }); puts("PASSED")})

      # DevOps v2 Phase 3: the gate READS GitHub CI's verdict for the frozen SHA — the
      # local suite is demoted — but the invariant this test pins is unchanged: the gate
      # mutates NOTHING (no primary lock, no primary writes) before ship authority.
      assert_includes out, "GitHub CI verdict for frozen", "the gate reads the CI verdict on the frozen SHA: #{out}"
      refute_includes out, "SUITE", "the demoted local suite must NOT run — CI is the verdict"
      refute_includes out, "PRIMARY-LOCK-TAKEN",
                      "the gate has nothing to serialize against the primary any more — it must not take its lock"
      refute_includes out, "PRIMARY-WRITE",
                      "no checkout/pull/merge/push before ship authority — a declined confirm must change nothing"
      assert_includes out, "PASSED"
    end
  end
  # [unit] No `--reason` → hard abort, and the suite is neither run NOR skipped. The
  # reason is the whole record: it is what a reader of the release sees next to a gate
  # that never ran, so an unexplained skip may not exist.
  def test_skip_test_gate_demands_a_reason
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + SKIP_GATE_STUB
      out = run_cli(["--yes", "--skip-test-gate"], setup: setup,
                    call: %{begin; test_gate("x", frozen_sha: #{GATE_SHA.inspect}); puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

      assert_includes out, "ABORTED", "an unexplained skip must not ship"
      assert_includes out, "--skip-test-gate requires --reason"
      assert_includes out, "recorded on the release as a red gate", "…and says what the reason is FOR"
      refute_includes out, "SUITE", "the abort runs nothing"
      refute_includes out, "PASSED"
    end
  end

  # [unit] With a reason (and --yes standing in for the confirm), the gate SKIPS: it
  # runs no suite, it does not even PIN the workspace — and it records a RED
  # ship_test_gate SOP carrying the reason and naming the SHA that shipped
  # uncertified. RED, not green: a gate that did not run is not a gate that passed,
  # and the old registry-blanking trick left a record that read "already green".
  def test_skip_test_gate_with_a_reason_records_a_red_gate_sop_and_runs_no_suite
    Dir.mktmpdir do |dir|
      setup = %(def repo_path(_repo) = #{dir.inspect}\n) + SKIP_GATE_STUB
      out = run_cli(["--yes", "--skip-test-gate", "--reason", "gate host postgres is down"], setup: setup,
                    call: %{$gate_sops = []; test_gate("x", frozen_sha: #{GATE_SHA.inspect}); puts("SOPS " + $gate_sops.inspect); puts("PASSED")})

      assert_includes out, "SKIPPED BY OPERATOR", "the skip is LOUD in the run's own output"
      assert_includes out, "gate host postgres is down", "…carrying the operator's reason"

      sops = out.lines.find { |l| l.start_with?("SOPS") }
      assert sops, "the skip must record a gate SOP: #{out}"
      assert_includes sops, %("sop"=>"ship_test_gate"), "recorded against the gate it skipped"
      assert_includes sops, %("result"=>"fail"),
                      "RED — a gate that did NOT run is not a green gate; this is the record the old " \
                      "registry-blanking trick never left"
      assert_includes sops, "SKIPPED BY OPERATOR (--skip-test-gate): gate host postgres is down"
      assert_includes sops, %(was NOT read on #{GATE_SHA[0, 7]}), "…naming the SHA that ships uncertified"

      refute_includes out, "SUITE", "the suite must NOT run — that is what was asked for"
      refute_includes out, "DB-PREPARE", "…and nothing prepares a workspace that will never be used"
      refute_includes out, "WORKSPACE", "…the gate returns before it even pins one"
      assert_includes out, "PASSED", "the ship rides on (the operator owns this call)"
    end
  end
  def test_ship_dry_run_publishes_gems_first_with_skip_idempotency
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "gem studio-engine 0.9.0", "the gem is shipped by its resolved version"
    assert_includes out, "skip if already live", "publish is idempotent against RubyGems"
    # No "ABORT if yanked" branch: yank safety is delegated to `gem push` failing
    # closed (the versions API omits yanked versions, so there's nothing to detect
    # in the listing). The dry-run plan must NOT promise a listing-based yank abort.
    refute_includes out, "yanked", "ship has no listing-based yank check in its plan"
    assert_includes out, "tag v0.9.0", "publish tags the published version"
  end

  def test_ship_dry_run_runs_the_auto_repin_pass
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "auto-repin consumers of studio-engine"
    assert_includes out, "bundle lock --update", "re-pin re-locks the consumer against the published gem"
  end

  def test_ship_dry_run_dispatches_per_repo_prod_adapters
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    # hub: git_push_heroku is now a REF PUSH of the frozen SHA (no checkout, no
    # local branch) — the dry-run must show what actually runs.
    assert_includes out, "push heroku bbbbbbb:refs/heads/main"
    assert_includes out, "https://mcritchie.studio/up"
    # satellite: repo_script runs the repo's own deploy; the repo owns smoke/rollback
    assert_includes out, "bin/deploy --yes"
    assert_includes out, "repo owns its smoke + rollback"
  end

  def test_ship_dry_run_test_cmd_gate_hub_only
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    # hub carries a conductor test_cmd; satellites self-gate (skip it).
    assert_includes out, HUB_GATE_CMD, "the hub runs its conductor test_cmd before prod"
    assert_includes out, "self-gates", "a repo_script satellite skips the conductor test_cmd"
  end

  def test_ship_dry_run_ships_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "frozen", "ship fast-forwards each repo to its QA-frozen SHA"
    assert_includes out, "bbbbbbb", "the hub's frozen SHA prefix appears in the plan"
  end

  def test_ship_dry_run_order_is_gems_then_hub_then_satellites
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gem_at = out.index("gem studio-engine") # gem publish
    hub_at = out.index("push heroku bbbbbbb:refs/heads/main")  # hub DEPLOY (the test gate runs up front, in run_ship_gate)
    sat_at = out.index("bin/deploy --yes")  # satellite's deploy

    assert gem_at && hub_at && sat_at, "all three phases must appear"
    assert_operator gem_at, :<, hub_at, "gems publish before the hub deploys"
    assert_operator hub_at, :<, sat_at, "the hub deploys before the satellites"
  end

  # --- Steffon ship gate: full e2e on the FROZEN SHA, THEN ship authority (§1.2) ---

  def test_ship_runs_the_steffon_e2e_gate_before_ship_authority_and_any_deploy
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    gate_at   = out.index("Steffon ship gate")
    e2e_at    = out.index(HUB_GATE_CMD)                # the hub's highest-tier run on the frozen SHA
    ship_at   = out.index("taking production authority") # the ship-authority step (unique marker; --mode ask|timed|auto)
    deploy_at = out.index("push heroku bbbbbbb:refs/heads/main")

    assert gate_at && e2e_at && ship_at && deploy_at, "gate, e2e, ship authority, and a deploy must all appear"
    assert_operator gate_at, :<, ship_at, "the Steffon gate precedes ship authority"
    assert_operator e2e_at, :<, ship_at, "the full suite runs on the frozen SHA BEFORE ship authority"
    assert_operator ship_at, :<, deploy_at, "ship authority precedes any deploy"
  end

  def test_ship_steffon_gate_reads_the_ci_verdict_for_the_frozen_sha
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)
    # DevOps v2 Phase 3: the gate reads GitHub CI's verdict for the frozen hub SHA
    # (the local suite is demoted); the plan still names that frozen SHA.
    assert_includes out, "Steffon ship gate"
    assert_includes out, "FROZEN ship SHA"
    assert_includes out, "bbbbbbb", "the gate is judged on the hub's QA-frozen SHA"
  end

  def test_ship_dry_run_states_the_partial_ship_policy_and_executes_nothing
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    assert_includes out, "abort on first failure", "partial-ship policy is surfaced"
    assert_includes out, "DRY RUN", "a dry-run executes nothing"
  end
  def test_gem_version_for_reads_the_frozen_ref_not_the_stale_local_checkout
    out = run_cli(["--dry-run"], setup: GEM_VERSION_STUB,
                  call: "print(gem_version_for('studio-engine', GROUP, 'frozensha'))")
    assert_equal "0.11.0", out,
                 "the gem version is read at the QA-frozen SHA (the version that publishes), not stale local main"
  end

  def test_gem_version_for_falls_back_to_the_local_checkout_without_a_frozen_ref
    # No frozen ref to read (a release prepared before SHA recording) → the local
    # checkout is the documented fallback. Proves the fix preserved the fallback.
    out = run_cli(["--dry-run"], setup: GEM_VERSION_STUB,
                  call: "print(gem_version_for('studio-engine', GROUP, nil))")
    assert_equal "0.10.0", out, "with no frozen ref the resolver falls back to the local checkout"
  end
  def test_ship_publishes_a_version_bumped_gem_instead_of_skipping_it
    out = run_cli(["--yes"], call: "ship", setup: PUBLISH_DECISION_STUB)

    assert_includes out, "PUBLISH-CALLED studio-engine 0.11.0",
                     "a gem bumped above the live version publishes (resolved from the frozen SHA)"
    refute_includes out, "already live on RubyGems — skip publish",
                     "the resolver must not read stale local 0.10.0 and skip the real publish"
    # the pre-flight reflects the same truth — the bumped version will publish
    assert_includes out, "studio-engine 0.11.0: not published — will publish"
  end

  # [integration] publish-gems-before-qa's ship half: prepare already published
  # 0.11.0 BEFORE QA, so ship's publish is the idempotent VERIFY — it skips the
  # push (RubyGems forbids a re-push) and the train still completes the gem's
  # release → main collapse.
  def test_ship_publish_is_an_idempotent_skip_after_prepare_already_published
    setup = PUBLISH_DECISION_STUB.sub(
      '[{ "number" => "0.10.0" }] # 0.10.0 LIVE, 0.11.0 not yet',
      '[{ "number" => "0.10.0" }, { "number" => "0.11.0" }] # prepare already published 0.11.0'
    )
    out = run_cli(["--yes"], call: "ship", setup: setup)

    assert_includes out, "studio-engine 0.11.0: LIVE on RubyGems — will skip", "the pre-flight sees it live"
    assert_includes out, "already live on RubyGems — skip publish", "ship verifies, never re-pushes"
    refute_includes out, "PUBLISH-CALLED", "no second publish of a version prepare already pushed"
  end
  # [integration] THE acceptance: a dirty, off-main app primary — a live feature
  # session's floor — must NOT abort the ship. It gets a note and the deploy rides on.
  def test_ship_preflight_does_not_abort_on_a_dirty_off_main_app_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        if repo == "turf-monster"
          { "repo" => repo, "branch" => "feat/live-session", "dirty" => true,
            "dirty_files" => ["app/models/pick.rb"], "tracked_dirty" => ["app/models/pick.rb"] }
        else
          { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
        end
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, [], #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "PASSED", "a dirty app primary must never abort a production ship: #{out}"
    refute_includes out, "ABORTED"
    assert_includes out, "NOTE, not a blocker", "…it says so plainly"
    assert_includes out, "turf-monster", "the note names the repo"
    assert_includes out, "rescue/turf-monster-", "…and prints the labeled-branch rescue"
    assert_includes out, "Nothing here is discarded, and nothing is stashed",
                    "it must PROMISE the session's work survives — never offer a stash or a discard"
  end

  # [integration] The ONE primary-state hazard that survives: a gem is BUILT from its
  # primary (gem build packages what is on disk), so a modified TRACKED file there
  # would be PUBLISHED — irreversibly. That aborts, BEFORE anything is published, and
  # the abort hands over the rescue.
  def test_ship_preflight_aborts_on_a_gem_primary_with_modified_tracked_files
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => ["lib/studio/version.rb"], "tracked_dirty" => ["lib/studio/version.rb"] } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "uncommitted tracked code in a gem repo would be PUBLISHED — fail closed"
    refute_includes out, "PASSED"
    assert_includes out, "studio-engine",         "the abort names the gem"
    assert_includes out, "lib/studio/version.rb", "…and the file that would ship"
    assert_includes out, "BEFORE publishing",     "…and that nothing has been published yet"
    assert_includes out, "rescue/studio-engine-", "…and hands over the labeled-branch rescue"
    assert_includes out, "nothing is stashed and nothing is discarded",
                    "never tell an operator to stash or discard a live session's work"
  end

  # [integration] UNTRACKED files in a gem primary are NOT a publish hazard — the
  # gemspec's file list is `git ls-files`, so they cannot be packaged. They must not
  # gate a ship (that would just re-invent the abort class we removed).
  def test_ship_preflight_ignores_untracked_files_in_a_gem_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => ["scratch.rb"], "tracked_dirty" => [] } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "PASSED", "an untracked scratch file in a gem repo is not packaged — it must not gate the ship"
    refute_includes out, "ABORTED"
  end

  # [integration] A generated artifact (a retro doc / the worktree ledger) routinely
  # sits uncommitted and must not gate a gem build either — the same narrow allowlist.
  def test_ship_preflight_ignores_generated_artifacts_in_a_gem_primary
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        files = ["docs/agents/maintenance/delete-later.md"]
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => files, "tracked_dirty" => files } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); puts('PASSED'); rescue SystemExit; puts('ABORTED'); end")

    assert_includes out, "PASSED", "a generated artifact is not real dirt"
    refute_includes out, "ABORTED"
  end

  # [integration] The preflight PINS each app's ship workspace at the frozen SHA
  # before anything is published — so a broken worktree aborts while the release is
  # still fully recoverable, never mid-train.
  def test_ship_preflight_pins_the_ship_workspaces_at_the_frozen_sha
    setup = <<~RUBY
      def repo_git_state(repo, _path)
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
      def with_ship_workspace(repo) = yield
      def ship_workspace!(repo, sha)
        $stdout.puts("PIN \#{repo} @ \#{sha}")
        "/tmp/_ship/\#{repo}"
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "ship_preflight(#{APP_GROUPS}, [], #{SHIP_SHAS}); puts('PASSED')")

    assert_includes out, "PIN mcritchie-studio @ abc1234", "the hub's ship workspace is pinned at its frozen SHA"
    assert_includes out, "PIN turf-monster @ def5678",     "…and the satellite's at its own"
    assert_includes out, "PASSED"
  end

  def test_ship_dry_run_previews_the_preflight_without_touching_git
    # In dry-run the preflight prints its plan and runs NO real git (so a dry-run
    # never aborts on a legitimately-dirty dev sibling). repo_git_state raises if
    # consulted, proving the DRY branch skips it.
    setup = SHIP_STUB + %(\ndef repo_git_state(*); raise "git consulted in dry-run preflight"; end)
    out = run_cli(["--dry-run"], call: "ship", setup: setup)
    assert_includes out, "ship preflight", "ship previews the preflight in dry-run"
    assert_includes out, "ship workspace", "…and previews the workspace pin the real run does"
  end

  # [integration] Real code dirt beside a generated artifact: in a GEM primary it
  # still gates (it would be published); in an APP primary it is only advised on.
  def test_ship_preflight_gem_gate_separates_real_dirt_from_a_generated_artifact
    setup = NO_WORKSPACE + <<~RUBY
      def repo_git_state(repo, _path)
        files = ["docs/agents/audits/retro-rel-1.md", "lib/studio/engine.rb"]
        return { "repo" => repo, "branch" => "main", "dirty" => true,
                 "dirty_files" => files, "tracked_dirty" => files } if repo == "studio-engine"
        { "repo" => repo, "branch" => "main", "dirty" => false, "dirty_files" => [], "tracked_dirty" => [] }
      end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "begin; ship_preflight(#{APP_GROUPS}, #{GEM_GROUPS}, #{SHIP_SHAS}); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "real code dirt in a gem repo would be published — it still gates"
    assert_includes out, "lib/studio/engine.rb", "the abort names the real dirty file"
    refute_includes out, "retro-rel-1.md", "the generated artifact is not named as dirt"
  end
end
