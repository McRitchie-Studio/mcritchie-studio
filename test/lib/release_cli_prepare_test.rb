# frozen_string_literal: true

# `bin/release init` and `bin/release prepare`: the dry-run plan, the merge-forward
# ordering, QA dispatch, the QA dyno boot wait and the Steffon handoff.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_prepare_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliPrepareTest < ReleaseCliHarness
  # --- init --dry-run: create the persistent `release` branch per repo ---

  def test_init_dry_run_previews_the_release_branch_push_per_repo
    out = run_cli(["--dry-run"], call: "init")

    # Idempotent push of origin/main → origin/release in every registered repo.
    assert_includes out, "origin/main:refs/heads/release",
                     "init must preview creating the persistent release branch"
    # Both a gem repo and the app repos are seeded (producer + consumers).
    assert_includes out, "studio-engine"
    assert_includes out, "mcritchie-studio"
    # More than one repo gets the branch (gems + apps).
    assert_operator out.scan("origin/main:refs/heads/release").size, :>=, 2
  end

  # --- prepare --dry-run: deploy origin/release per app (no branch-cut) ---

  def test_prepare_dry_run_deploys_origin_release_per_app
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # Each APP repo deploys the persistent `release` branch by ref — qa-server
    # resolves origin/release in the sibling and pushes its SHA.
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release"
    assert_includes out, "bin/qa-server deploy turf-monster origin/release"
  end

  def test_prepare_dry_run_runs_the_merge_forward_guard
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "merge-forward guard",
                     "prepare must keep `release` ahead of main"
  end

  # [integration] THE PLACEMENT FIX (rel-20260809-3b8f3d, 2026-08-09). The guard
  # used to run inside the QA-deploy loop, i.e. AFTER the pre-QA gate — so a merge
  # that landed moved origin/release PAST the SHA the gate had just certified, and
  # QA deployed (and ship froze) a tree G3 never verified. It now runs above the
  # gate, and this pins that order in the real emitted plan, not just in the source.
  def test_prepare_dry_run_merge_forward_precedes_the_gate_and_the_qa_deploy
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # Anchor on each phase's OWN step line. Plain "pre-QA gate" also appears in
    # the lock-bump message ("…the pre-QA gate, QA, and prod must all build this
    # SAME committed lock"), which sits earlier and would make this pass on prose.
    merge  = out.index("merge-forward guard: origin/release must CONTAIN")
    gate   = out.index("pre-QA gate: GitHub CI")
    deploy = out.index("bin/qa-server deploy")

    assert merge && gate && deploy, "the plan must show all three phases: #{out}"
    assert_operator merge, :<, gate,
                    "merge-forward comes BEFORE the gate, so the gate certifies the tree that deploys"
    assert_operator gate, :<, deploy, "the gate still precedes the QA deploy"
  end
  # DevOps v2 Phase 2: the hub's QA deploy is scoped by prod_deploy strategy. A
  # github_actions app dispatches ONE qa-deploy.yml run at the release tip
  # (workflow_dispatch, so the N PR-merge pushes of the sweep don't fire N deploys);
  # a non-Actions app keeps the local qa-server force-push, byte-unchanged.
  def test_prepare_dry_run_dispatches_github_actions_qa_only_for_the_hub
    out = run_cli(["--dry-run"], call: "prepare", setup: GHA_QA_STUB)

    assert_includes out, "gh workflow run qa-deploy.yml",
                     "the hub (github_actions) dispatches qa-deploy.yml for QA, not qa-server"
    refute_includes out, "bin/qa-server deploy mcritchie-studio",
                     "the hub no longer QA-deploys via qa-server"
    assert_includes out, "bin/qa-server deploy turf-monster origin/release",
                     "a non-github_actions app keeps the qa-server force-push (mechanic scoped to the hub)"
  end

  def test_prepare_dry_run_no_longer_cuts_a_release_branch_or_merges_members
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    # The old model cut release/<slug> and merged member branches in prepare; the
    # persistent-branch model does neither — merges happen at PR-merge time.
    refute_includes out, "checkout -b", "prepare must not cut a release branch"
    refute_includes out, "merge --no-ff", "prepare must not merge member branches"
  end
  def test_prepare_dry_run_warns_and_skips_an_app_with_no_qa_environment
    out = run_cli(["--dry-run"], call: "prepare", setup: ELIGIBILITY_STUB)

    assert_includes out, "tax-studio: no QA environment registered",
                     "a registered app with no qa_environments.yml entry must warn"
    refute_includes out, "bin/qa-server deploy tax-studio",
                     "an app with no QA env is skipped, not deployed"
    # a properly registered app on the same release still deploys
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release"
  end

  # --- the Steffon handoff line: printed on QA-green ONLY ------------------------

  def test_prepare_prints_the_steffon_handoff_only_on_qa_green
    out = run_cli(["--yes"], call: "prepare", setup: SWEEP_FLOW_STUB)

    assert_includes out, "Assembled rel-sweep"
    assert_includes out, "hand off to Steffon: `bin/release ship`", "QA-green prepare hands the RC to Steffon"
  end

  def test_prepare_omits_the_steffon_handoff_when_qa_is_not_green
    setup = SWEEP_FLOW_STUB + %(\ndef wait_for_boot(_url) = false)
    out = run_cli(["--yes"], call: "prepare", setup: setup)

    assert_includes out, "QA is NOT green", "the boot failure is reported"
    assert_includes out, "Prepared (NOT assembled — QA not green)"
    # prepare RETURNS NORMALLY here, so the wrapper that runs it prints `PREPARE EXIT: 0`
    # over a release that assembled nothing — measured on rel-20260907-14cff2, where the
    # zero was read as success. The block has to say so where the failure is read.
    assert_includes out, "the exit code is NEVER the QA verdict",
                    "a NOT-green prepare must warn that its own exit 0 is not a verdict"
    refute_includes out, "hand off to Steffon",
                    "a NOT-green prepare must not point at `bin/release ship` — there is nothing to ship yet"
    refute_includes out, "QA-GREEN-CALL", "no flip on a QA-red prepare"
  end

  # --- prepare: wait_for_boot closes the /up-smoke race before assembling ---

  def test_prepare_dry_run_waits_for_the_qa_dyno_to_boot
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)
    assert_includes out, "wait for boot", "prepare must poll /up before recording QA + assembling"
    assert_includes out, "/up until 200"
  end
  def test_wait_for_boot_retries_until_up_returns_200
    out = run_cli(["--yes"], setup: WAIT_BOOT_STUB,
                  call: "print(wait_for_boot('https://qa.example', attempts: 5, delay: 0))")
    assert_includes out, "booted after 3 polls", "polls /up until it returns 200"
    assert out.end_with?("true"), "returns true once booted: #{out.inspect}"
  end

  def test_wait_for_boot_times_out_to_false_when_never_200
    setup = <<~RUBY
      def sh(*_a, **_k) = ["503", true]
      def sleep(*_a); end
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: "print(wait_for_boot('https://qa.example', attempts: 3, delay: 0))")
    assert_includes out, "never returned 200 after 3 polls"
    assert out.end_with?("false"), "times out to false: #{out.inspect}"
  end

  def test_wait_for_boot_skips_an_empty_url
    out = run_cli(["--yes"], setup: "", call: "print(wait_for_boot('', attempts: 3, delay: 0))")
    assert_equal "true", out, "an app with no QA url has nothing to smoke"
  end
end
