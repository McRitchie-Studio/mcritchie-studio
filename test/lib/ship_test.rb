# frozen_string_literal: true

# [integration] Harness tests for bin/ship — the fast-lane handoff wrapper
# (commit → fast-check → push → non-draft PR into accepted → record pr_url →
# dor-check → move submitted → read-back verify). Follows the house seam
# pattern (test/lib/fast_check_test.rb): the REAL script is shelled via Open3
# against a throwaway git repo (with a real bare `origin`, so the push lane is
# exercised for real), with the board/cert/gate/GitHub CLIs stubbed via SHIP_*
# env seams. The skip decisions themselves are unit-tested in
# test/lib/fast_lane_test.rb.
# Run directly:
#   ruby -Itest test/lib/ship_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "open3"
require "time"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../../bin/lib/full_suite_gate"

class ShipTest < Minitest::Test
  BIN = File.expand_path("../../bin/ship", __dir__)
  SLUG = "fast-lane-demo"
  BRANCH = "feat/#{SLUG}"
  TASK_URL = "https://mcritchie.studio/tasks/#{SLUG}"
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999"

  # A throwaway repo on the task branch with a bare `origin` carrying an
  # `accepted` base — so push runs against a real remote, no network. Yields
  # the workdir with one committed baseline and one uncommitted edit (the
  # change ship's commit step must land).
  def with_repo
    Dir.mktmpdir do |root|
      dir = File.join(root, "work")
      origin = File.join(root, "origin.git")
      FileUtils.mkdir_p(dir)
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      write.call("app.rb", "puts :v1\n")
      write.call(".gitignore", "stub.log\n*-stub\n")
      git.call("init -q -b #{BRANCH}")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      assert system("git init -q --bare #{origin}"), "bare origin"
      git.call("remote add origin #{origin}")
      git.call("push -q origin #{BRANCH}:accepted")
      write.call("app.rb", "puts :v2\n")
      yield dir
    end
  end

  # A stub CLI following the fast_check_test pattern: logs "<MARKER>\t<argv...>"
  # to STUB_LOG; exits 1 when FAIL_<MARKER>=1 (after logging + printing). The
  # TASK stub serves `show` from TASK_SHOW_JSON — and from TASK_SHOW_JSON_MOVED
  # once a `move` call has been logged, modeling board persistence for the
  # read-back verify. The GH stub serves `pr list` from GH_PR_LIST_JSON and
  # prints a PR URL on `pr create`.
  def write_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      log = ENV.fetch("STUB_LOG")
      # One log line per call: escape embedded newlines (the PR body is multi-line).
      File.open(log, "a") { |f| f.puts(["#{marker}", *ARGV].map { |a| a.to_s.gsub("\\n", "\\\\n") }.join("\\t")) }
      if "#{marker}" == "TASK" && ARGV.first == "show"
        moved = File.readlines(log).any? { |l| l.split("\\t")[0, 2] == %w[TASK move] }
        puts(moved && ENV["TASK_SHOW_JSON_MOVED"] ? ENV["TASK_SHOW_JSON_MOVED"] : ENV["TASK_SHOW_JSON"])
      end
      if "#{marker}" == "GH" && ARGV[0, 2] == %w[pr list]
        puts ENV.fetch("GH_PR_LIST_JSON", "[]")
      end
      if "#{marker}" == "GH" && ARGV[0, 2] == %w[pr create]
        puts "#{PR_URL}"
      end
      exit(ENV["FAIL_#{marker}"] == "1" ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  def task_record(stage: "building", pr_url: nil, checks_run: [], claim: nil)
    JSON.generate(
      "slug" => SLUG, "stage" => stage, "title" => "Fast lane demo",
      "metadata" => { "devops" => {
        "branch" => BRANCH, "worktree_slug" => SLUG, "pr_url" => pr_url,
        "acceptance" => ["ship collapses the handoff"], "checks_run" => checks_run
      }.merge(claim || {}).compact }
    )
  end

  # A build-claim devops slice with a lease `expires_in` seconds out — the shape
  # `move building` writes (see test/lib/task_cli_test.rb's twin).
  def claim_of(session:, nonce:, expires_in: 300)
    { "claimed_session" => session, "claim_nonce" => nonce,
      "claim_expires_at" => (Time.now + expires_in).utc.iso8601 }
  end

  # Run bin/ship with every seam stubbed. Returns [out, err, status, log_lines]
  # where log_lines is the parsed stub log ([[marker, argv...], ...] in call order).
  def run_ship(dir, args: [SLUG], extra_env: {}, show_json: nil, moved_json: nil)
    log = File.join(dir, "stub.log")
    env = SessionEnv.neutralized({
      "SHIP_ROOT" => dir,
      "SHIP_TASK_BIN" => write_stub(dir, "task-stub", "TASK"),
      "SHIP_FAST_CHECK_BIN" => write_stub(dir, "fast-stub", "FAST"),
      "SHIP_DOR_CHECK_BIN" => write_stub(dir, "dor-stub", "DOR"),
      "SHIP_GH_BIN" => write_stub(dir, "gh-stub", "GH"),
      "SHIP_ACTIVITY_BIN" => write_stub(dir, "activity-stub", "ACTIVITY"),
      "STUB_LOG" => log,
      "TASK_SHOW_JSON" => show_json || task_record,
      "TASK_SHOW_JSON_MOVED" => moved_json || task_record(stage: "submitted", pr_url: PR_URL)
    }.merge(extra_env))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, err, status, lines]
  end

  def markers(lines)
    lines.map { |l| l[0, 2].join(" ") }
  end

  # --- the green path ----------------------------------------------------------

  def test_green_path_runs_every_step_in_order_and_verifies
    with_repo do |dir|
      out, err, status, lines = run_ship(dir)

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      assert_equal ["TASK show", "FAST #{SLUG}", "GH pr", "GH pr", "TASK update", "DOR #{SLUG}",
                    "TASK move", "TASK show"], markers(lines),
                   "steps must run in the handoff order (commit + push are real git, not stubs)"

      # The commit landed and was pushed: origin's branch tip equals local HEAD.
      assert_equal "", `git -C #{dir} status --porcelain`.strip, "ship must commit the dirty tree"
      head = `git -C #{dir} rev-parse HEAD`.strip
      assert_equal head, `git -C #{dir} rev-parse origin/#{BRANCH}`.strip, "the branch must be pushed"
      assert_includes `git -C #{dir} log -1 --format=%s`, "Fast lane demo",
                      "the commit message defaults to the task title"

      create = lines.find { |l| l[0] == "GH" && l[2] == "create" }
      assert create, "a PR must be created"
      assert_equal "accepted", create[create.index("--base") + 1], "the PR must target accepted"
      assert create[create.index("--body") + 1].start_with?(TASK_URL),
             "the PR body must LEAD with the task URL"
      refute_includes create, "--draft", "ship must never open a draft PR"

      assert_equal [SLUG, "--pr-url", PR_URL],
                   lines.find { |l| l[0, 2] == %w[TASK update] }[2, 3]
      assert_equal [SLUG, "submitted"],
                   lines.find { |l| l[0, 2] == %w[TASK move] }[2, 2]

      assert_includes out, "Task: #{TASK_URL}"
      assert_includes out, "PR: #{PR_URL}"
      assert_includes out, "stage: submitted (read back verified)"
    end
  end

  def test_commit_message_flag_overrides_the_title
    with_repo do |dir|
      _out, err, status, = run_ship(dir, args: [SLUG, "-m", "Land the widget cache"])

      assert status.success?, err
      assert_includes `git -C #{dir} log -1 --format=%s`, "Land the widget cache"
    end
  end

  # --- rebased branch: force-with-lease, never a bare force --------------------

  # [unit] A rebased branch pushes with --force-with-lease. Rebasing is ROUTINE
  # here — accepted moves constantly and desks rebase onto it — so a plain
  # `git push` that fails non-fast-forward on our OWN superseded history must not
  # strand the ship (git's "pull before pushing" hint is the WRONG remedy: it
  # would merge the pre-rebase history back in). ship replays with
  # --force-with-lease, which is safe: it refuses if the remote moved under us.
  def test_rebased_branch_pushes_with_force_with_lease
    with_repo do |dir|
      git = ->(a) { assert system("git -C #{dir} #{a} >/dev/null 2>&1"), "git #{a}" }
      git.call("add -A"); git.call("commit -q -m v2")            # C1
      git.call("push -q -u origin #{BRANCH}")                    # origin/#{BRANCH} = C1 (remote-tracking too)
      git.call("commit --amend -q -m v2-rebased")               # rewrite history → local diverges from C1
      File.write(File.join(dir, "app.rb"), "puts :v3\n")        # a dirty edit for ship's commit step

      out, err, status, = run_ship(dir)

      assert status.success?, "a rebased branch must ship with no manual force, got:\n#{err}\n#{out}"
      head = `git -C #{dir} rev-parse HEAD`.strip
      assert_equal head, `git -C #{dir} rev-parse origin/#{BRANCH}`.strip,
                   "the rebased history must land on origin via --force-with-lease"
    end
  end

  # [unit] The distinction the fix must NOT collapse: a GENUINE foreign commit on
  # the remote is refused, never force-pushed away. The foreign push is staged
  # from a SEPARATE clone so our remote-tracking origin/#{BRANCH} stays STALE —
  # exactly as production (fixtures-live-in-one-clone). Stage it in `dir` and the
  # remote-tracking ref would freshen, and --force-with-lease would wrongly PASS.
  def test_foreign_commit_on_remote_is_refused_not_clobbered
    with_repo do |dir|
      origin = File.join(File.dirname(dir), "origin.git")
      git = ->(a) { assert system("git -C #{dir} #{a} >/dev/null 2>&1"), "git #{a}" }
      git.call("add -A"); git.call("commit -q -m v2")           # C1
      git.call("push -q -u origin #{BRANCH}")                   # origin/#{BRANCH} = C1, remote-tracking = C1

      # A DIFFERENT actor pushes to origin/#{BRANCH} from ITS OWN clone, so `dir`
      # never learns of it — remote-tracking stays C1, as it would in production.
      clone2 = File.join(File.dirname(dir), "clone2")
      assert system("git clone -q #{origin} #{clone2} >/dev/null 2>&1"), "second clone"
      c2 = ->(a) { assert system("git -C #{clone2} -c user.email=x@y.z -c user.name=x #{a} >/dev/null 2>&1"), "git #{a}" }
      c2.call("checkout -q -B #{BRANCH} origin/#{BRANCH}")
      File.write(File.join(clone2, "foreign.txt"), "someone else's work\n")
      c2.call("add -A"); c2.call("commit -q -m foreign")
      c2.call("push -q origin #{BRANCH}")
      foreign_sha = `git -C #{clone2} rev-parse HEAD`.strip

      # We rebase locally too, so a plain push is non-ff and a naive fix would force.
      git.call("commit --amend -q -m v2-rebased")
      File.write(File.join(dir, "app.rb"), "puts :v3\n")

      _out, err, status, lines = run_ship(dir)

      refute status.success?, "a genuine foreign commit must refuse, not force-push"
      assert_match(/reconcile|fetch|foreign/i, err, "the refusal must point at fetch/reconcile")
      assert_equal foreign_sha, `git -C #{origin} rev-parse #{BRANCH}`.strip,
                   "the foreign commit must survive — ship must NEVER clobber it"
      refute(lines.any? { |l| l[0, 2] == %w[TASK move] }, "a refused push must not reach the submit step")
    end
  end

  # --- narration (fast-lane-narrates-activities) -------------------------------
  # ship closes the cycle's activity trail (the twin of begin's orient open) with
  # a real outcome naming the submitted stage and the PR.

  def test_ship_closes_the_activity_trail_naming_the_pr_and_submitted
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-ship-narrate" })

      assert status.success?, err
      activity = lines.find { |l| l[0] == "ACTIVITY" }
      assert activity, "ship must close the activity trail"
      assert_equal "end", activity[1], "ship CLOSES the trail (end), never leaves one open"
      outcome = activity[activity.index("--outcome") + 1]
      assert_match(/submitted/i, outcome, "the outcome names the submitted stage")
      assert_includes outcome, PR_URL, "the outcome names the PR"
    end
  end

  def test_ship_narration_is_non_fatal
    with_repo do |dir|
      _out, err, status, = run_ship(dir, extra_env: {
        "CLAUDE_CODE_SESSION_ID" => "sess-ship-narrate", "FAIL_ACTIVITY" => "1"
      })

      assert status.success?, "a failing narration CLI must never fail the ship: #{err}"
    end
  end

  def test_ship_without_a_session_does_not_narrate
    with_repo do |dir|
      _out, _err, status, lines = run_ship(dir)

      assert status.success?
      refute(lines.any? { |l| l[0] == "ACTIVITY" }, "a session-less ship must not narrate")
    end
  end

  # --- idempotent resume -------------------------------------------------------

  def test_resume_repairs_a_draft_misbased_pr_and_skips_landed_steps
    with_repo do |dir|
      # A previous run already landed everything: commit done, cert recorded for
      # THIS exact tree, PR open (but draft + mis-based), pr_url stored, task
      # already submitted. Rerun must repair the PR and re-verify — nothing else.
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")
      fingerprint = FullSuiteGate.fingerprint(dir)
      refute_nil fingerprint, "fixture repo must fingerprint"
      recorded = task_record(stage: "submitted", pr_url: PR_URL,
                             checks_run: ["[fast-cert@#{fingerprint}] green"])
      existing = JSON.generate([{ "number" => 999, "url" => PR_URL, "isDraft" => true,
                                  "baseRefName" => "main" }])

      out, err, status, lines = run_ship(dir, extra_env: { "GH_PR_LIST_JSON" => existing },
                                              show_json: recorded, moved_json: recorded)

      assert status.success?, "resume must complete, got:\n#{err}\n#{out}"
      refute_includes markers(lines), "FAST #{SLUG}", "a fresh fingerprint-bound cert must skip fast-check"
      refute(lines.any? { |l| l[0] == "GH" && l[2] == "create" }, "an open PR must never be duplicated")
      assert(lines.any? { |l| l[0] == "GH" && l[1, 2] == %w[pr ready] }, "a draft PR must be marked ready")
      edit = lines.find { |l| l[0] == "GH" && l[1, 2] == %w[pr edit] }
      assert edit, "a mis-based PR must be retargeted"
      assert_equal "accepted", edit[edit.index("--base") + 1]
      refute(lines.any? { |l| l[0, 2] == %w[TASK update] }, "an equal pr_url must not be re-recorded")
      refute(lines.any? { |l| l[0, 2] == %w[TASK move] }, "an already-submitted task must not move again")
      assert_includes out, "stage: submitted (read back verified)"
    end
  end

  # --- red gates stop the line, resumably --------------------------------------

  def test_red_fast_check_aborts_before_push_pr_and_move
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "FAIL_FAST" => "1" })

      refute status.success?, "a red cert must fail the ship"
      assert_includes err, "fast-check failed"
      assert_includes err, "re-run bin/ship #{SLUG}", "the failure must name the resume"
      assert_equal ["TASK show", "FAST #{SLUG}"], markers(lines), "nothing may run past the red cert"
      _remote = `git -C #{dir} rev-parse origin/#{BRANCH} 2>/dev/null`.strip
      refute $?.success?, "the branch must NOT be pushed on a red cert"
    end
  end

  def test_red_dor_check_aborts_before_move
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "FAIL_DOR" => "1" })

      refute status.success?, "a red DoR verdict must fail the ship"
      assert_includes err, "dor-check refused"
      refute(lines.any? { |l| l[0, 2] == %w[TASK move] }, "the task must not move on a red DoR")
    end
  end

  def test_read_back_verify_fails_loud_when_the_move_never_persisted
    with_repo do |dir|
      # The board echoes success but the persisted stage never advances: the
      # post-move read serves the same [building] record.
      stuck = task_record(stage: "building", pr_url: PR_URL)
      out, err, status, lines = run_ship(dir, moved_json: stuck)

      refute status.success?, "a non-persisted move must fail the ship"
      assert_includes err, "read-back verify FAILED"
      assert(lines.any? { |l| l[0, 2] == %w[TASK move] }, "the move must have been attempted")
      refute_includes out, "stage: submitted (read back verified)"
    end
  end

  # --- builder ownership + the build-stage seam --------------------------------
  # Ship hands off a BUILD: it must refuse a task that never walked the building
  # seam, and refuse a task a DIFFERENT live instance is building — both BEFORE
  # any side effect (commit/push/PR/move). The green-path tests above double as
  # the session-less degrade vector (the harness env is session-neutralized).

  def test_ship_refuses_an_unbuilt_designed_task
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, show_json: task_record(stage: "designed"))

      refute status.success?, "a designed task must not be teleported past the building seam"
      assert_includes err, "ship hands off a BUILD"
      assert_includes err, "bin/task begin #{SLUG}", "the refusal must name the claim path"
      assert_equal [%w[TASK show]], lines.map { |l| l[0, 2] }, "no step may run on an unbuilt task"
      refute_equal "", `git -C #{dir} status --porcelain`.strip, "the dirty tree must be left uncommitted"
    end
  end

  def test_ship_refuses_a_task_a_different_live_instance_holds
    with_repo do |dir|
      foreign = task_record(claim: claim_of(session: "sess-rival-9999", nonce: "inst-A"))
      _out, err, status, lines = run_ship(
        dir, show_json: foreign,
        extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111", "TASK_CLAIM_NONCE" => "inst-default" }
      )

      refute status.success?, "shipping another builder's live task must refuse (non-zero exit)"
      assert_match(/different live instance/i, err, "the refusal must say who holds it")
      assert_match(/…9999/, err, "the refusal must name the holder")
      assert_includes err, "bin/task begin #{SLUG} --steal", "the refusal must name the takeover path"
      assert_equal [%w[TASK show]], lines.map { |l| l[0, 2] }, "no step may run past the ownership refusal"
      refute_equal "", `git -C #{dir} status --porcelain`.strip, "no commit may land on a foreign-held task"
    end
  end

  def test_ship_proceeds_when_this_instance_holds_the_claim
    with_repo do |dir|
      own = task_record(claim: claim_of(session: "sess-shipper-1111", nonce: "inst-default"))
      _out, err, status, lines = run_ship(
        dir, show_json: own,
        extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111", "TASK_CLAIM_NONCE" => "inst-default" }
      )

      assert status.success?, "the claim holder must ship freely, got:\n#{err}"
      assert(lines.any? { |l| l[0, 2] == %w[TASK move] }, "the holder's ship must reach the move")
    end
  end

  def test_read_back_verify_refuses_a_wrong_persisted_pr_url
    with_repo do |dir|
      # The --pr-url write silently fails while a STALE pr_url (a different PR)
      # sits on the board: the read-back must pin the EXACT URL this run
      # recorded — any non-empty value must not pass as persistence.
      stale = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/111"
      out, err, status, lines = run_ship(
        dir,
        show_json: task_record(stage: "building", pr_url: stale),
        moved_json: task_record(stage: "submitted", pr_url: stale)
      )

      refute status.success?, "a persisted pr_url that is not the one just recorded must fail the verify"
      assert_includes err, "read-back verify FAILED"
      assert_includes err, stale, "the refusal must name the URL the board holds"
      assert_includes err, PR_URL, "the refusal must name the URL this run recorded"
      assert(lines.any? { |l| l[0, 2] == %w[TASK update] }, "the record step must have been attempted")
      refute_includes out, "PR: #{stale}", "the summary must never print the wrong PR as shipped"
    end
  end

  # --- guards ------------------------------------------------------------------

  def test_task_past_the_seam_is_left_alone
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, show_json: task_record(stage: "reviewed", pr_url: PR_URL))

      assert status.success?
      assert_includes err, "past the submitted seam"
      assert_equal [%w[TASK show]], lines.map { |l| l[0, 2] }, "no step may run on a past-seam task"
      assert_includes out, "Task: #{TASK_URL}"
      refute_equal "", `git -C #{dir} status --porcelain`.strip, "the dirty tree must be left uncommitted"
    end
  end

  def test_wrong_branch_refuses_before_any_write
    with_repo do |dir|
      assert system("git -C #{dir} checkout -q -b some-other-branch")
      _out, err, status, lines = run_ship(dir)

      refute status.success?
      assert_includes err, "not the task branch"
      assert_equal [%w[TASK show]], lines.map { |l| l[0, 2] }
      refute_equal "", `git -C #{dir} status --porcelain`.strip, "no commit may land from the wrong branch"
    end
  end
end
