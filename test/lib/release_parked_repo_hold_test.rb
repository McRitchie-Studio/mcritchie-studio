# frozen_string_literal: true

# [integration] bin/release's PARKED-REPO HOLD (sweep-ignores-parked-repos).
#
#   ruby -Itest test/lib/release_parked_repo_hold_test.rb
#
# THE DEFECT. `bin/release prepare` took every `reviewed` task the board offered and
# promoted every repo those tasks named. Nothing between the detection read and the
# QA deploy asked the registry whether a repo was one the conductor sweeps, so a
# reviewed task on rolio (`dormant`), tax-studio (`planned`) or chain-ops (`blocked`)
# would have been promoted onto `release` and deployed. The only ladder read on the
# way, verify_release_carries_accepted!, intersected the plan with the three-rung set
# — which quietly dropped a parked repo from its check instead of refusing it.
#
# THE DECISION IS HOLD, NOT ABORT, on the self-healing sweep: the task is named on a
# `⚠ HELD` line, left in its stage, never promoted, recorded or deployed, and the rest
# of the sweep carries on — the same shape as the unstamped-merge hold. On the
# EXPLICIT `bin/release merge <slug>` the operator named the task, so there it is a
# refusal, like that command's own unstamped-merge abort.
#
# These drive the REAL prepare/merge in a subprocess with the board seam (`conductor`)
# stubbed and a DRY run, so nothing reaches git, GitHub, Heroku or the board. The
# registry gains an invented `parked-app` rather than borrowing rolio, so the tests
# pin the rule and survive the day rolio is re-laddered.
#
# A NEW FILE, not an addition to test/lib/release_cli_test.rb — that file is frozen at
# its ceiling in config/test_health.yml, and this is the out it names.
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
