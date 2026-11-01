# frozen_string_literal: true

# [integration] bin/release's PARKED-REPO HOLD: a reviewed task on a repo the conductor does not
# sweep must never be promoted, recorded or deployed. HOLD, NOT ABORT, on the self-healing
# sweep: a `⚠ HELD` line, task left in its stage, sweep carries on. On explicit `bin/release
# merge <slug>` it is a refusal. REAL prepare/merge, `conductor` stubbed, DRY run. An invented
# `parked-app` in the registry pins the rule and survives rolio being re-laddered. A FILE OF ITS
# OWN: release CLI files are frozen. The ratchet's config is deliberately not named by path: a
# citation would map this file to every edit of that config in bin/fast-check.
# History: task sweep-ignores-parked-repos.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseCliParkedRepoHoldTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  # Fail-closed board base: a real board call from this file is a bug by definition.
  UNROUTABLE_API_BASE = "http://127.0.0.1:1"

  PARKED_FIXTURE = %(RELEASE_REPOS["apps"]["parked-app"] = { "ladder" => "dormant" }\n)

  def setup
    @lock_dir = Dir.mktmpdir("release-parked-locks")
  end

  def teardown
    FileUtils.remove_entry(@lock_dir) if @lock_dir && File.directory?(@lock_dir)
  end

  def run_ruby(script)
    env = OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => @lock_dir, "TASK_API_BASE" => UNROUTABLE_API_BASE)
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)
    assert status.success?, "bin/release subprocess failed (exit #{status.exitstatus.inspect}):\n#{out}\n#{err}"
    out
  end

  def row(slug, repos, merged: "accepted", stage: "reviewed")
    { "slug" => slug, "stage" => stage, "merged" => merged, "repo" => repos.first, "kind" => "app",
      "pr_url" => "https://github.com/McRitchie-Studio/#{repos.first}/pull/1", "repos" => repos,
      "pr_urls" => repos.to_h { |r| [ r, "https://github.com/McRitchie-Studio/#{r}/pull/1" ] } }
  end

  # The board seam: detection answers with `tasks`; every WRITE prints a marker so a
  # test can prove none happened; the read-only repo_plan read answers "no release
  # yet", which is what a dry run over a fresh candidate sees.
  def conductor_stub(tasks)
    <<~RUBY
      TASKS = JSON.parse(#{JSON.generate(tasks).inspect})
      def conductor(ruby, read_only: false)
        puts("CONDUCTOR-WRITE " + ruby[0, 60]) unless read_only
        if ruby.include?("sweep_candidates") || ruby.include?("screen_merge")
          return { "tasks" => TASKS, "release" => nil,
                   "screen" => { "rows" => TASKS.map { |t| { "slug" => t["slug"], "stage" => t["stage"], "status" => "eligible" } },
                                 "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
        end
        {}
      end
    RUBY
  end

  def prepare_dry_run(tasks)
    run_ruby(%(ARGV.replace(["--dry-run"]); load #{BIN.inspect}; #{PARKED_FIXTURE}#{conductor_stub(tasks)}; prepare))
  end

  # ── prepare: the self-healing sweep HOLDS ─────────────────────────────────────

  def test_prepare_holds_a_task_on_a_parked_repo_and_sweeps_its_neighbour
    out = prepare_dry_run([ row("rolio-feature", ["parked-app"]), row("hub-feature", ["mcritchie-studio"]) ])

    held = out.lines.find { |l| l.include?("HELD rolio-feature") }
    refute_nil held, "the parked task must get a HELD line:\n#{out}"
    assert_includes held, "parked-app (ladder: dormant)", "the line names the parked repo and why"
    assert_includes out, "promote accepted → release in mcritchie-studio", "the neighbour still promotes"
    refute_includes out, "release in parked-app", "a parked repo is NEVER promoted:\n#{out}"
    assert_includes out, "1 task(s) would sweep", "the count excludes the held task"
    refute_includes out, "CONDUCTOR-WRITE", "a dry run records nothing"
  end

  def test_prepare_holds_a_mixed_task_whole_and_promotes_neither_repo
    out = prepare_dry_run([ row("span-hub-and-rolio", %w[mcritchie-studio parked-app]) ])

    held = out.lines.find { |l| l.include?("HELD span-hub-and-rolio") }
    refute_nil held, "the mixed task must be held:\n#{out}"
    assert_includes held, "whole task"
    refute_match(/promote accepted → release in/, out,
                 "neither half of a mixed task rides — shipping the live half breaks the assembled invariant")
  end

  # ── merge: the explicit command REFUSES ───────────────────────────────────────

  def test_merge_refuses_a_named_task_on_a_parked_repo_before_promoting
    script = %(ARGV.replace(["rolio-feature", "--dry-run"]); load #{BIN.inspect}; #{PARKED_FIXTURE}) +
             conductor_stub([ row("rolio-feature", ["parked-app"]) ]) +
             %(; begin; merge; puts "NO-ABORT"; rescue SystemExit => e; puts "ABORTED: " + e.message; end)
    out = run_ruby(script)

    assert_includes out, "ABORTED:", "an explicitly named parked task must refuse, not vanish:\n#{out}"
    assert_includes out, "parked-app (ladder: dormant)"
    refute_includes out, "promote accepted → release", "the refusal comes before the promote"
  end

  # ── the deploy half's entry gate: a parked repo in the plan REFUSES ──────────

  def verify(plan_repos, argv)
    groups = plan_repos.map { |r| { "repo" => r } }
    run_ruby(%(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{PARKED_FIXTURE}) + <<~RUBY)
      def ladder_ahead_states(repos: nil, require_checkout: false)
        puts("LADDER-READ")
        { "release" => [], "accepted" => [], "unreadable" => [] }
      end
      begin
        verify_release_carries_accepted!(#{groups.inspect}, "rel-parked", "assembling")
        puts("NO-ABORT")
      rescue SystemExit => e
        puts("ABORTED: " + e.message)
      end
    RUBY
  end

  def test_verify_refuses_a_deploy_plan_that_names_a_parked_repo
    out = verify(%w[mcritchie-studio parked-app], ["--yes"])

    assert_includes out, "ABORTED:", "the backstop must refuse, not skip:\n#{out}"
    assert_includes out, "parked-app (ladder: dormant)"
    refute_includes out, "LADDER-READ", "it refuses before any git read"
  end

  def test_verify_previews_the_refusal_under_a_dry_run
    out = verify(%w[parked-app], ["--dry-run"])

    assert_includes out, "NO-ABORT"
    assert_match(/would REFUSE.*parked-app \(ladder: dormant\)/, out)
  end

  def test_verify_does_not_refuse_a_plan_of_three_rung_repos
    out = verify(%w[mcritchie-studio], ["--dry-run"])

    refute_match(/REFUSE/, out)
    assert_includes out, "NO-ABORT"
  end
end
