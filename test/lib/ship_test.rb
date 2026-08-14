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
  # `base_files` land in the INIT commit, so they are on `accepted` before the branch
  # diverges — the only way to model "this migration is already on the base ref".
  def with_repo(base_files: {})
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
      base_files.each { |rel, body| write.call(rel, body) }
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
  # read-back verify. The GH stub serves the `--head` `pr list` (is MY PR already
  # open?) from GH_PR_LIST_JSON and the un-headed one (which OTHER PRs are open?)
  # from GH_PR_LIST_SIBLINGS_JSON — two different questions that must be able to
  # carry two different answers. The GH stub serves `pr list` from GH_PR_LIST_JSON and
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
        puts ENV.fetch(ARGV.include?("--head") ? "GH_PR_LIST_JSON" : "GH_PR_LIST_SIBLINGS_JSON", "[]")
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


  # THE REGRESSION CARL CAUGHT. `gh_capture`'s mint-FAILURE branch returned an
  # undefined local (`first` after a rename to `failure`) — valid Ruby, a NameError
  # at runtime, on the exact path that promises to report gh's original error. It
  # survived because bin/ship is rubocop-excluded and nothing executed the branch.
  # This drives a real ship whose gh ALWAYS refuses on credentials and whose mint
  # ALWAYS fails, so the branch runs: ship must fail with gh's REAL error, not a
  # NameError, and must never hang or mint anything real.
  def test_mint_failure_reports_ghs_original_error_and_never_raises
    with_repo do |dir|
      refusing_gh = File.join(dir, "gh-refuse")
      File.write(refusing_gh, "#!/bin/sh\necho 'GraphQL: Resource not accessible by " \
                              "personal access token (createPullRequest)' >&2\nexit 1\n")
      File.chmod(0o755, refusing_gh)

      out, err, status, = run_ship(dir, extra_env: {
        "SHIP_GH_BIN" => refusing_gh,
        # The BROKER cannot run → the failure branch. This must name the seam
        # GhAuthRetry actually reads (GH_AUTH_TOKEN_BIN): acquisition moved into
        # bin/gh-token, so the old GH_AUTH_MINT_BIN pin steered nothing and this
        # test fell through to the REAL broker — reaching the operator's live
        # 1Password for the App private key (proven with an `op` recorder), and
        # still passing green. A dead seam in a credential test is invisible.
        "GH_AUTH_TOKEN_BIN" => "/nonexistent/gh-token"
      })

      combined = "#{err}\n#{out}"
      refute status.success?, "a gh that always refuses must fail the ship"
      refute_match(/NameError|undefined local variable|undefined method .first./, combined,
                   "the mint-failure branch must not crash — that was the shipped bug")
      assert_match(/not accessible by personal access token/, combined,
                   "and must surface gh's ORIGINAL error, which is the whole promise of that branch")
      assert_match(/minting a GitHub App token/, combined, "the retry was attempted")
    end
  end

  # --- the green path ----------------------------------------------------------

  def test_green_path_runs_every_step_in_order_and_verifies
    with_repo do |dir|
      out, err, status, lines = run_ship(dir)

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      # Three GH calls, not two: `pr list` (is one already open?), `pr create`, then
      # the same-file OVERLAP ADVISORY's own `pr list` — asked after the PR exists so
      # it can exclude this one, and before the DoR verdict so the builder reads it
      # while a deliberate choice is still cheap. See bin/lib/pr_overlap.rb.
      assert_equal ["TASK show", "FAST #{SLUG}", "GH pr", "GH pr", "GH pr", "TASK update", "DOR #{SLUG}",
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

  # --- duplicate migration installs (BLOCKS) -----------------------------------
  #
  # [integration] Two branches install ONE engine migration under two host timestamps.
  # The FILES do not conflict — different names — so git merges both cleanly and only
  # db/schema.rb objects; resolve that carelessly and Rails raises
  # DuplicateMigrationNameError on EVERY db:migrate, including the Heroku release
  # phase. Three live incidents on 2026-08-13/14. Unlike the same-file advisory beside
  # it, this one is fatal: there is no state of the world where two copies are correct.

  ENGINE_HEADER = "# This migration comes from studio_engine (originally 20260813220000)"
  BASE_INSTALL = "db/migrate/20260813221100_add_standard_user_profile_columns.studio_engine.rb"
  SECOND_INSTALL = "db/migrate/20260813223520_add_standard_user_profile_columns.studio_engine.rb"

  def engine_migration(header: ENGINE_HEADER, klass: "AddStandardUserProfileColumns")
    "#{header}\nclass #{klass} < ActiveRecord::Migration[8.1]\n  def change; end\nend\n"
  end

  def write_migration(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # The turf #312-vs-already-merged-copy shape: the other copy is on `accepted`. Local
  # git only — this leg still fires when GitHub is unreachable.
  def test_a_second_install_of_a_base_ref_migration_blocks_the_ship
    with_repo(base_files: { BASE_INSTALL => engine_migration }) do |dir|
      write_migration(dir, SECOND_INSTALL, engine_migration)
      out, err, status, lines = run_ship(dir)

      refute status.success?, "a duplicate migration install must fail the ship:\n#{err}\n#{out}"
      combined = "#{err}\n#{out}"
      assert_match(/DUPLICATE MIGRATION INSTALL/, combined)
      assert_includes combined, SECOND_INSTALL, "the operator must see WHICH two files collide"
      assert_includes combined, BASE_INSTALL
      assert_match(/DuplicateMigrationNameError/, combined, "and the actual consequence")
      assert_match(/Heroku release phase/, combined, "which is a DEPLOY break")
      assert_match(/the other DROPS it/, combined, "and the resolution all three incidents used")
      refute_includes markers(lines), "TASK move",
                      "the task must NOT reach submitted with a duplicate migration on the branch"
    end
  end

  # turf #312 vs #313: the other copy is on a sibling OPEN PR, where only PATHS are on
  # offer. The class key is derivable from a filename alone, so the existing `pr list`
  # payload is enough and the check costs no extra round trip.
  def test_a_sibling_open_pr_installing_the_same_migration_blocks_the_ship
    siblings = JSON.generate([{ number: 313, title: "Turf adopts profile migration",
                                url: "https://github.com/o/r/pull/313", headRefName: "feat/turf-adopts",
                                files: [{ path: BASE_INSTALL }] }])
    with_repo do |dir|
      write_migration(dir, SECOND_INSTALL, engine_migration)
      out, err, status, lines = run_ship(dir, extra_env: { "GH_PR_LIST_SIBLINGS_JSON" => siblings })

      refute status.success?, "#{err}\n#{out}"
      combined = "#{err}\n#{out}"
      assert_match(/DUPLICATE MIGRATION INSTALL/, combined)
      assert_match(%r{PR #313 https://github.com/o/r/pull/313}, combined,
                   "the COLLIDING PR must be named, with its URL")
      refute_includes markers(lines), "TASK move"
    end
  end

  # THE NEGATIVE CONTROL, and it matters more than the two above: a check that flagged
  # an ordinary install would wedge every migration-bearing task in the shop. A brand
  # new engine migration, with `accepted` and a sibling PR each carrying a DIFFERENT
  # one, must ship green and say nothing.
  def test_a_legitimate_single_install_ships_green
    siblings = JSON.generate([{ number: 313, title: "Something else", url: "https://o/313",
                                headRefName: "feat/other",
                                files: [{ path: "db/migrate/20260810120000_create_widgets.studio_engine.rb" }] }])
    with_repo(base_files: { BASE_INSTALL => engine_migration }) do |dir|
      write_migration(dir, "db/migrate/20260814094500_add_widget_prefs.studio_engine.rb",
                      engine_migration(header: "# This migration comes from studio_engine (originally 20260814090000)",
                                       klass: "AddWidgetPrefs"))
      out, err, status, lines = run_ship(dir, extra_env: { "GH_PR_LIST_SIBLINGS_JSON" => siblings })

      assert status.success?, "a normal engine install must ship:\n#{err}\n#{out}"
      refute_match(/DUPLICATE MIGRATION/, "#{err}\n#{out}")
      assert_includes markers(lines), "TASK move", "and must reach the submitted seam"
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

  # ── the ROOT-GUARD lane ────────────────────────────────────────────────────
  #
  # Every test above pins SHIP_ROOT, which short-circuits the root guard entirely —
  # so ship's guard branch had NO coverage at all. That gap is the reason a wrong
  # claim about this lane survived a round of review: with nothing exercising it,
  # "it still ships" could be asserted without ever being observed.
  #
  # WHAT IS ACTUALLY TRUE, measured (2026-08-09): ship REFUSES a detached HEAD at the
  # task's own desk, and always has. It dies at the branch guard in bin/ship — which
  # is PRE-EXISTING, live on `main`, and untouched by this PR — because a detached
  # HEAD is not the task branch. There was never a regression here to restore, and
  # these tests assert the refusal, not a lane that does not exist.
  #
  # What the root-guard line in bin/ship does change is WHICH refusal you get. Without
  # it the root guard speaks first and says the desk "is not <slug>'s tree", which is
  # false — it IS the task's desk; only HEAD is detached — and it sends the builder
  # somewhere else. With it, ship falls through to the branch guard, which names the
  # real problem and the real fix (finish the rebase). Same exit code, same steps run,
  # better diagnosis. That is the whole of its effect, and it is what these tests pin.

  # Run ship from `cwd` with NO SHIP_ROOT, so the real root guard runs.
  def run_ship_from(cwd, dir, projects)
    log = File.join(dir, "stub.log")
    env = SessionEnv.neutralized(
      "SHIP_ROOT" => nil,
      "SHIP_PROJECTS_DIR" => projects,
      "SHIP_TASK_BIN" => write_stub(dir, "task-stub", "TASK"),
      "SHIP_FAST_CHECK_BIN" => write_stub(dir, "fast-stub", "FAST"),
      "SHIP_DOR_CHECK_BIN" => write_stub(dir, "dor-stub", "DOR"),
      "SHIP_GH_BIN" => write_stub(dir, "gh-stub", "GH"),
      "SHIP_ACTIVITY_BIN" => write_stub(dir, "activity-stub", "ACTIVITY"),
      "STUB_LOG" => log,
      "TASK_SHOW_JSON" => task_record,
      "TASK_SHOW_JSON_MOVED" => task_record(stage: "submitted", pr_url: PR_URL)
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, SLUG, chdir: cwd)
    [out, err, status]
  end

  # The task's own desk at <projects>/<app>/.worktrees/<slug>, on the task branch.
  def with_task_desk
    Dir.mktmpdir do |root|
      projects = File.realpath(root)
      desk = File.join(projects, "myapp", ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      g = ->(args) { assert(system("git -C #{desk} #{args} >/dev/null 2>&1"), "git #{args}") }
      File.write(File.join(desk, ".gitignore"), "stub.log\n*-stub\n")
      File.write(File.join(desk, "app.rb"), "puts :v1\n")
      g.call("init -q -b #{BRANCH}")
      g.call("config user.email tester@example.com")
      g.call("config user.name tester")
      g.call("add -A")
      g.call("commit -q -m init")
      yield projects, desk
    end
  end

  def test_a_detached_head_at_the_tasks_own_desk_is_refused_by_the_branch_guard
    # Physically at the task's desk, HEAD detached (mid-rebase is the ordinary way to
    # get here). ship refuses — it always has, at the pre-existing branch guard — and
    # this asserts that refusal POSITIVELY, including which guard produced it. The
    # earlier version of this test asserted only negatives under the name
    # "still_ships", which described a behavior that does not occur.
    with_task_desk do |projects, desk|
      assert system("git -C #{desk} checkout -q --detach HEAD")
      out, err, status = run_ship_from(desk, desk, projects)
      blame = out + err

      refute status.success?, "a detached HEAD is not the task branch; ship refuses"
      assert_includes blame, "not the task branch", "the BRANCH guard is what refuses"
      assert_includes blame, "finish the rebase", "and it names the fix that actually applies"

      # The root guard must NOT be the one speaking: the desk IS the task's tree, so
      # "not <slug>'s tree" would be a false diagnosis pointing the builder elsewhere.
      # This is the one thing the bin/ship root-guard line changes, so it is asserted
      # positively rather than as a bare refute of a string that may never appear.
      refute_includes blame, "is not fast-lane-demo's tree",
                      "the root guard must defer to the branch guard at the task's own desk"
    end
  end

  def test_a_foreign_checkout_is_still_refused_or_re_rooted
    # The other direction, so the fix above cannot become a blanket bypass: standing
    # somewhere that is NOT the task's desk must still be caught.
    with_task_desk do |projects, _desk|
      stranger = File.join(projects, "myapp")
      FileUtils.mkdir_p(stranger)
      assert system("git -C #{stranger} init -q -b release")
      assert system("git -C #{stranger} config user.email t@t.co")
      assert system("git -C #{stranger} config user.name t")
      File.write(File.join(stranger, "README.md"), "hub\n")
      assert system("git -C #{stranger} add -A && git -C #{stranger} commit -q -m init")

      _out, err, status = run_ship_from(stranger, stranger, projects)

      refute status.success?, "a foreign checkout must not ship silently"
      assert_includes err, SLUG
    end
  end
end
