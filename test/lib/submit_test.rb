# frozen_string_literal: true

# [integration] Harness tests for bin/submit — the fast-lane handoff wrapper
# (commit → push → non-draft PR into accepted → record pr_url → optional
# pre-flight → CI wait → dor-check → move submitted → read-back verify). Follows the house seam
# pattern (test/lib/fast_check_test.rb): the REAL script is shelled via Open3
# against a throwaway git repo (with a real bare `origin`, so the push lane is
# exercised for real), with the board/cert/gate/GitHub CLIs stubbed via SHIP_*
# env seams. The skip decisions themselves are unit-tested in
# test/lib/fast_lane_test.rb.
# Run directly:
#   ruby -Itest test/lib/submit_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/ship_wait"
require_relative "../../bin/lib/desk_session"
require "json"
require "open3"
require "socket"
require "time"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../support/fake_desk"
require_relative "../../bin/lib/tree_fingerprint"

class SubmitTest < Minitest::Test
  BIN = File.expand_path("../../bin/submit", __dir__)
  SLUG = "fast-lane-demo"
  BRANCH = "feat/#{SLUG}"

  # The board bin/submit renders task links against — DERIVED from the pin, not
  # spelled out. It used to be the literal "https://mcritchie.studio/tasks/…",
  # which passed only because run_ship left TASK_API_BASE unpinned and bin/submit
  # fell through to its production default. Two problems with that: the assertion
  # "the PR body must LEAD with the task URL" was really asserting the production
  # HOST, and no containment floor could pin the board without a false red here.
  # Deriving it keeps the assertion about the URL's SHAPE, which is what these
  # tests are actually for.
  TASK_URL = "#{OutboundSeams::UNROUTABLE}/tasks/#{SLUG}"
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
      write.call(".gitignore", "stub.log\nstub-tokens.log\n*-stub\n")
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
      # bin/dor-check runs twice: the 0/8 pre-check (--precheck) and the 7/8 verdict.
      # The pre-check logs and exits as PRECHECK, so FAIL_DOR still means "the verdict
      # refuses" and a test can refuse the pre-check alone (FAIL_PRECHECK).
      stub_name = ("#{marker}" == "DOR" && ARGV.include?("--precheck")) ? "PRECHECK" : "#{marker}"
      # The pre-flight stub carries a THIRD column: the tip of origin/#{BRANCH} as
      # seen from its cwd (ship's root), or "unpushed". It is the only vantage point
      # from which "had the push landed when the pre-flight ran?" can be answered.
      extra = []
      if "#{marker}" == "FAST"
        tip = IO.popen(%w[git rev-parse --verify --quiet origin/#{BRANCH}], err: File::NULL, &:read).to_s.strip
        extra << (tip.empty? ? "unpushed" : tip)
      end
      # One log line per call: escape embedded newlines (the PR body is multi-line).
      File.open(log, "a") { |f| f.puts([stub_name, *ARGV, *extra].map { |a| a.to_s.gsub("\\n", "\\\\n") }.join("\\t")) }
      # The board token each child saw, one line per call, so a test can say whether
      # ONE token served the whole ship or none did. A child mints for itself only
      # when this is blank; the stub records the fact, never a secret.
      if (tokens = ENV["STUB_TOKEN_LOG"].to_s) != ""
        File.open(tokens, "a") { |f| f.puts(["#{marker}", ENV["AGENT_API_TOKEN"].to_s].join("\\t")) }
      end
      # SNAPSHOT THE LIVE PRESENCE CLAIM. A claim is REWRITTEN at each boundary and
      # cleared on exit, so it cannot be observed after the run — only from inside
      # it. Each stub runs DURING a known phase (GH during 3/8, FAST during 5/8,
      # DOR during 7/8), which makes these stubs the only vantage point from which
      # the phase sequence is visible at all.
      if (snap = ENV["PRESENCE_SNAP_DIR"].to_s) != ""
        claims = Dir.glob(File.join(ENV.fetch("CLAUDE_PROJECTS_DIR"), ".agents", "sessions", "*.presence-*"))
        File.write(File.join(snap, "#{marker}.json"), claims.map { |c| File.read(c) }.join)
      end
      # The review-lease read ship's holder refusal makes. TASK_REVIEW_CLAIM_JSON is
      # the board's answer; unset means "no claim row", which is a real answer.
      if "#{marker}" == "TASK" && ARGV[0, 2] == %w[review-claim status]
        exit 1 if ENV["FAIL_REVIEW_CLAIM"] == "1"
        puts ENV.fetch("TASK_REVIEW_CLAIM_JSON", '{"holder":null}')
      end
      exit 1 if "#{marker}" == "TASK" && ARGV.first == "update" && ENV["STUB_FAIL_TASK_UPDATE"] == "1"
      if "#{marker}" == "TASK" && ARGV.first == "show"
        moved = File.readlines(log).any? { |l| l.split("\\t")[0, 2] == %w[TASK move] }
        puts(moved && ENV["TASK_SHOW_JSON_MOVED"] ? ENV["TASK_SHOW_JSON_MOVED"] : ENV["TASK_SHOW_JSON"])
      end
      if "#{marker}" == "GH" && ARGV[0, 2] == %w[pr list]
        head_at = ARGV.index("--head")
        head = head_at ? ARGV[head_at + 1] : nil
        if head.nil? || head.empty?
          puts ENV.fetch("GH_PR_LIST_SIBLINGS_JSON", "[]")
        elsif head == "#{BRANCH}"
          puts ENV.fetch("GH_PR_LIST_JSON", "[]")
        else
          # A THIRD question, and it must be able to answer differently from the other
          # two: is the base this PR sits on another OPEN PR's head — a deliberate
          # stack — or a branch nobody is shipping, which is the mis-based case?
          exit 1 if ENV["FAIL_GH_PARENT_LIST"] == "1"
          puts ENV.fetch("GH_PR_PARENT_JSON", "[]")
        end
      end
      if "#{marker}" == "GH" && ARGV[0, 2] == %w[pr create]
        puts "#{PR_URL}"
      end
      # The what-failed digest at 7/8 reads the red PR's checks, then each failing
      # job's log. `gh pr checks` exits 8 on a red PR, with the JSON on stdout.
      if "#{marker}" == "GH" && ARGV[0, 2] == %w[pr checks] && ENV["GH_PR_CHECKS_JSON"]
        puts ENV["GH_PR_CHECKS_JSON"]
        exit 8
      end
      if "#{marker}" == "GH" && ARGV[0] == "api" && ARGV[1].to_s.end_with?("/logs") && ENV["GH_JOB_LOG"]
        print ENV["GH_JOB_LOG"]
        exit 0
      end
      # EXIT_<MARKER> pins an EXACT status, because one stub now has to model a
      # verdict that is neither success nor failure: bin/fast-check exits 2 to say
      # DEFERRED (not certified, but carry on to the PR — capped-cert-blocks-the-pr).
      # FAIL_<MARKER>=1 stays the plain red.
      forced = ENV["EXIT_" + stub_name].to_s
      exit(forced.empty? ? (ENV["FAIL_" + stub_name] == "1" ? 1 : 0) : forced.to_i)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # `review: :absent` omits the review_in_progress column entirely — the older-board
  # case the holder refusal's UNKNOWN route exists for, and the default here so
  # every pre-existing test keeps the payload it was written against.
  # `built_by` names the CURRENT builder — the soul ship must author its commit
  # as. nil (the default) is compacted away, modelling a task that names nobody,
  # so every pre-existing test here keeps exactly the payload it was written
  # against.
  def task_record(stage: "building", pr_url: nil, checks_run: [], claim: nil, review: :absent,
                  built_by: nil)
    record = {
      "slug" => SLUG, "stage" => stage, "title" => "Fast lane demo",
      "metadata" => { "devops" => {
        "branch" => BRANCH, "worktree_slug" => SLUG, "pr_url" => pr_url, "built_by" => built_by,
        "acceptance" => ["ship collapses the handoff"], "checks_run" => checks_run
      }.merge(claim || {}).compact }
    }
    record["review_in_progress"] = review unless review == :absent
    JSON.generate(record)
  end

  # Run bin/submit with every seam stubbed. Returns [out, err, status, log_lines]
  # where log_lines is the parsed stub log ([[marker, argv...], ...] in call order).
  def run_ship(dir, args: [SLUG], extra_env: {}, show_json: nil, moved_json: nil)
    log = File.join(dir, "stub.log")
    env = OutboundSeams.env({
      "SHIP_ROOT" => dir,
      # The presence claim's store, PINNED — and pinned OUTSIDE the work repo on
      # purpose. Unpinned, the task-usage sandbox refuses the write outright (that
      # is the containment guarantee, asserted in its own test below); pinned INSIDE
      # `dir`, the marker would land in the working tree and ship's own 1/8 commit
      # would sweep it into the diff.
      "CLAUDE_PROJECTS_DIR" => presence_root(dir),
      "SHIP_TASK_BIN" => write_stub(dir, "task-stub", "TASK"),
      "SHIP_FAST_CHECK_BIN" => write_stub(dir, "fast-stub", "FAST"),
      "SHIP_DOR_CHECK_BIN" => write_stub(dir, "dor-stub", "DOR"),
      "SHIP_GH_BIN" => write_stub(dir, "gh-stub", "GH"),
      "SHIP_ACTIVITY_BIN" => write_stub(dir, "activity-stub", "ACTIVITY"),
      "STUB_LOG" => log,
      "STUB_TOKEN_LOG" => File.join(dir, "stub-tokens.log"),
      # The ship's OWN board mint (one token per run) resolves the secret through
      # the real chain — ENV, then the script's repo .env, then 1Password. Pinned
      # here so it stops at ENV: the board is unroutable in this harness, so the
      # mint fails fast and the children fall back to minting their own, and no
      # test can spend a vault read or read the desk's .env. A token test overrides
      # TASK_API_BASE with a stub board that answers the mint.
      "AGENT_API_SECRET" => "test-secret",
      # The CI settle wait (step 6/8) is left ARMED here and handed an injected
      # GREEN, rather than switched off: every test in this file then drives the
      # real step, so a wait that stopped being called — or that broke the handoff
      # — reddens the whole harness instead of only the cases written for it. A
      # default of `off` would have made the step provably present in three tests
      # and unexercised in twenty. Individual tests override SHIP_CI_STATE.
      "SHIP_CI_STATE" => "state:green",
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

  # Where run_ship pins the session-marker store: a sibling of the work repo, so
  # nothing written there can be swept into ship's commit.
  def presence_root(dir)
    File.join(File.expand_path("..", dir), "projects")
  end

  # Every presence claim on disk after a run, parsed. The glob is the one a reader
  # uses — <projects>/.agents/sessions/<id>.presence-<kind>-<pid>.
  def presence_claims(dir)
    Dir.glob(File.join(presence_root(dir), ".agents", "sessions", "*.presence-*"))
       .map { |p| [File.basename(p), JSON.parse(File.read(p))] }
  end


  # THE REGRESSION CARL CAUGHT. `gh_capture`'s mint-FAILURE branch returned an
  # undefined local (`first` after a rename to `failure`) — valid Ruby, a NameError
  # at runtime, on the exact path that promises to report gh's original error. It
  # survived because bin/submit is rubocop-excluded and nothing executed the branch.
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

  # --- the CI settle wait (step 6/8, gate-submit-on-green-ci) -------------------
  # The RULE is unit-tested in test/lib/ci_wait_test.rb with no clock and no gh.
  # These prove the rule is ON THE PATH — that bin/submit really calls it, that the
  # DoR gate still owns the verdict afterwards, and that neither give-up path can
  # advance a task on its own. A pin nobody exercised is advice.

  def test_the_wait_holds_the_task_in_building_when_ci_is_red
    with_repo do |dir|
      # Red CI, and a dor-check that refuses it — which is what the real gate does.
      # The point of the assertion pair below is the DIVISION OF LABOUR: the wait
      # settles and reports, and the REFUSAL still comes from dor-check.
      out, err, status, lines = run_ship(dir, extra_env: {
        "SHIP_CI_STATE" => "state:red", "FAIL_DOR" => "1"
      })
      combined = "#{err}\n#{out}"

      refute status.success?, "a red CI must not reach submitted"
      assert_match(/6\/8 ci — CI settled on red/, combined, "the wait must report the red it saw")
      assert_includes markers(lines), "DOR #{SLUG}", "dor-check still runs — the wait decides nothing"
      assert_match(/bin\/dor-check refused/, combined, "and the REFUSAL is dor-check's, not the wait's")
      # The task is left where it was. Ship never reached its move step.
      refute_includes markers(lines), "TASK move", "a red CI must leave the task in building"
    end
  end

  def test_a_green_ci_advances_through_the_gate_to_submitted
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, extra_env: { "SHIP_CI_STATE" => "state:green" })
      combined = "#{err}\n#{out}"

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      assert_match(/6\/8 ci — CI settled on green/, combined)
      # Order is the contract: the wait must finish BEFORE the verdict, or
      # dor-check grades a pending CI and credits the cert provisionally — which
      # is the exact behaviour this task exists to replace.
      ci_line = combined.index("6/8 ci — CI settled")
      dor_line = combined.index("7/8 dor —")
      assert ci_line && dor_line && ci_line < dor_line, "the wait must complete before the DoR verdict"
      assert_includes markers(lines), "TASK move"
    end
  end

  # Guard catalog row 1.10: the gate reads only a settled CI. A CI still running when
  # the wait gives up stops the handoff BEFORE the gate, so dor-check never meets it.
  def test_a_ci_that_never_finishes_stops_before_the_gate_rather_than_wedging
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, extra_env: {
        "SHIP_CI_STATE" => "state:pending", "SHIP_CI_WAIT_TIMEOUT" => "1"
      })
      combined = "#{err}\n#{out}"

      refute status.success?
      assert_match(/still pending/, combined, "the give-up path must name what it gave up on")
      assert_match(/resumes at 6\/8/, combined)
      refute_includes markers(lines), "DOR #{SLUG}", "the gate must not be called on an unsettled CI"
      refute_includes markers(lines), "TASK move"
    end
  end

  def test_a_ci_that_never_appears_stops_before_the_gate
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, extra_env: {
        "SHIP_CI_STATE" => "state:none", "SHIP_CI_WAIT_APPEARANCE" => "1"
      })
      combined = "#{err}\n#{out}"

      refute status.success?
      assert_match(/reports no CI checks/, combined)
      refute_includes markers(lines), "DOR #{SLUG}", "the gate must not be called on an absent CI"
    end
  end

  def test_a_disarmed_wait_still_reads_ci_once_and_stops_on_pending
    with_repo do |dir|
      _out, _err, status, lines = run_ship(dir, extra_env: {
        "SHIP_CI_WAIT" => "off", "SHIP_CI_STATE" => "state:pending"
      })

      refute status.success?
      refute_includes markers(lines), "DOR #{SLUG}", "a disarmed wait still never hands the gate a pending CI"
    end
  end

  def test_a_CI_READ_THAT_FAILS_is_not_reported_as_the_PR_having_no_CI
    with_repo do |dir|
      # The integration half of task ship-waiter-misreports-ci. On PR #1143 this
      # step printed "no CI run appeared ... treating this PR as having none" while
      # `gh pr checks` showed 12/12 GREEN — because :unverified (a gh/network fault)
      # was rendered with :none's sentence. The wording lives in ci_wait.rb; THIS
      # proves the honest wording is on the path a builder actually reads.
      out, err, status, lines = run_ship(dir, extra_env: {
        "SHIP_CI_STATE" => "state:unverified", "SHIP_CI_WAIT_APPEARANCE" => "1"
      })
      combined = "#{err}\n#{out}"

      refute_match(/no CI run appeared/, combined, "the read failed; GitHub never said this")
      refute_match(/having none/, combined, "and ship must not invite treating a green PR as CI-less")
      assert_match(%r{6/8 ci — could not read CI}, combined, "it must say the READ failed")
      assert_includes markers(lines), "DOR #{SLUG}", "and the gate still owns the verdict"
    end
  end

  def test_a_read_THE_TOKEN_WAS_REFUSED_points_at_the_token_not_at_the_repo
    with_repo do |dir|
      # F2, found reviewing task ship-waiter-misreports-ci. :unreadable is
      # ci_status.rb's own name for a 401/403 — the TOKEN could not read CI. It
      # SETTLES, because waiting cannot mend a credential, and that is exactly why it
      # needs its own line: the token-refresh advisory fired on :unverified (a
      # gh/network fault, which a re-run may clear by itself) and said NOTHING on the
      # one state whose remedy IS the token. A blind read that settles quietly is how
      # a reader mistakes it for a verdict.
      out, err, status, lines = run_ship(dir, extra_env: { "SHIP_CI_STATE" => "state:unreadable" })
      combined = "#{err}\n#{out}"

      assert_match(%r{6/8 ci — that read was REFUSED}, combined, "the refusal must be named, not settled quietly")
      assert_match(/gh-auth-refresh/, combined, "beside the remedy that actually applies to a 401/403")
      assert_includes markers(lines), "DOR #{SLUG}", "and the gate still owns the verdict"
      assert status.success?, "the advisory is a note, not a refusal:\n#{combined}"
    end
  end

  def test_the_wait_can_be_disarmed_and_says_so
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, extra_env: { "SHIP_CI_WAIT" => "off" })
      combined = "#{err}\n#{out}"

      assert status.success?
      assert_match(/6\/8 ci — wait disabled/, combined)
      assert_match(/reading CI once/, combined, "a disarmed wait reads CI once and says so")
      assert_includes markers(lines), "DOR #{SLUG}", "the gate runs either way"
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
      # The second `TASK show` is 5/8 asking the board whether it already derives the
      # PR url; this board (the stub) predates the field, so ship writes it itself.
      # The DoR pre-check (PRECHECK) and the pre-flight (FAST) come BEFORE the push and
      # the PR: they stop a push CI would turn red. The verdict (DOR) still follows CI.
      assert_equal ["TASK show", "PRECHECK #{SLUG}", "FAST #{SLUG}", "GH pr", "GH pr", "GH pr", "TASK show",
                    "TASK update", "DOR #{SLUG}", "TASK move"], markers(lines),
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

  # ── A DELIBERATE STACK IS NOT A MISTAKE (/tasks/ship-retargets-stacked-prs) ────
  #
  # MEASURED 2026-09-13 on turf #701, stacked on turf #624 by the operator's decision:
  # step 3/8 retargeted it to `accepted` because the base was not `accepted`, and that
  # ONE action produced three false refusals — the test-only claim broke (the observed
  # diff swelled to the parent's 6 files), the PR went DIRTY so GitHub queued no run at
  # all, and the [control] line "named no file from this diff". The ship had to be
  # finished by hand.
  #
  # The tell is on GitHub, not in the record: a base that is ANOTHER OPEN PR'S HEAD is a
  # stack. A merged parent, a closed-unmerged one, or a deleted branch is not — none of
  # them is open — so those stay repaired, which is what the retarget exists for.
  def stacked_pr(base) = JSON.generate([{ "number" => 999, "url" => PR_URL, "isDraft" => false,
                                          "baseRefName" => base }])

  def test_a_pr_based_on_an_open_prs_head_keeps_its_base
    with_repo do |dir|
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")
      parent = JSON.generate([{ "number" => 624, "url" => "https://github.com/o/r/pull/624" }])

      _out, err, status, lines = run_ship(dir, extra_env: {
        "GH_PR_LIST_JSON" => stacked_pr("feat/qa-shares-production-signing-key"),
        "GH_PR_PARENT_JSON" => parent
      })

      assert status.success?, "a stacked ship must complete, got:\n#{err}"
      refute(lines.any? { |l| l[0] == "GH" && l[1, 2] == %w[pr edit] },
             "step 3/8 retargeted a PR based on open PR #624's branch — that is a deliberate " \
             "stack, and retargeting it strands the ship exactly as it did on turf #701")
    end
  end

  # AN EMPTY baseRefName IS NOT A STACK (/tasks/review-guards-stacked-prs, third item).
  # `gh pr list --head "" --state open` is NO FILTER to real gh and returns EVERY open PR, so
  # an unread or absent base would make the probe name the FIRST open PR as this PR's parent
  # and preserve a MIS-BASED PR on the strength of a coincidence. No answer falls to the repair.
  def test_an_empty_base_ref_falls_to_the_repair_not_to_a_coincidental_parent
    with_repo do |dir|
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")
      siblings = JSON.generate([{ "number" => 42, "url" => "https://github.com/o/r/pull/42" }])

      _out, err, status, lines = run_ship(dir, extra_env: {
        "GH_PR_LIST_JSON" => stacked_pr(""),
        "GH_PR_LIST_SIBLINGS_JSON" => siblings
      })

      assert status.success?, "an empty base must not abort the ship, got:\n#{err}"
      edit = lines.find { |l| l[0] == "GH" && l[1, 2] == %w[pr edit] }
      assert edit, "an empty base is not a stack — it must still be retargeted"
      assert_equal "accepted", edit[edit.index("--base") + 1]
    end
  end

  # THE OTHER ARM, so the fix cannot become "never retarget". A base nobody has an open
  # PR for is the mis-based case the self-heal exists to repair.
  def test_a_pr_based_on_a_branch_with_no_open_pr_is_still_repaired
    with_repo do |dir|
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")

      _out, err, status, lines = run_ship(dir, extra_env: {
        "GH_PR_LIST_JSON" => stacked_pr("feat/parent-already-merged-and-deleted"),
        "GH_PR_PARENT_JSON" => "[]"
      })

      assert status.success?, "the repair path must still complete, got:\n#{err}"
      edit = lines.find { |l| l[0] == "GH" && l[1, 2] == %w[pr edit] }
      assert edit, "a base with no open PR is mis-based and must still be retargeted"
      assert_equal "accepted", edit[edit.index("--base") + 1]
    end
  end

  # AN UNREADABLE PROBE MUST NOT SILENTLY PRESERVE. Nothing downstream repairs a
  # mis-based PR — this retarget is the only thing that does — so an unanswered question
  # falls back to the repair, and says which way it fell.
  def test_an_unreadable_parent_probe_still_repairs_and_says_so
    with_repo do |dir|
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")

      out, err, status, lines = run_ship(dir, extra_env: {
        "GH_PR_LIST_JSON" => stacked_pr("feat/unknown"),
        "FAIL_GH_PARENT_LIST" => "1"
      })

      assert status.success?, "an unreadable probe must not abort the ship, got:\n#{err}"
      assert(lines.any? { |l| l[0] == "GH" && l[1, 2] == %w[pr edit] },
             "an unanswered probe must fall back to the repair")
      assert_match(/could not read whether an open PR/, "#{out}#{err}",
                   "the ship must say the probe failed, not imply it checked")
    end
  end

  def test_resume_repairs_a_draft_misbased_pr_and_skips_landed_steps
    with_repo do |dir|
      # A previous run already landed everything: commit done, PR open (but draft +
      # mis-based), pr_url stored, task already submitted. Rerun must repair the PR
      # and re-verify — nothing else durable. (The pre-flight records nothing, so
      # there is nothing for it to resume from; it simply runs again.)
      assert system("git -C #{dir} add -A >/dev/null 2>&1 && git -C #{dir} commit -q -m done")
      recorded = task_record(stage: "submitted", pr_url: PR_URL,
                             checks_run: ["[unit] bin/rails test test/models"])
      existing = JSON.generate([{ "number" => 999, "url" => PR_URL, "isDraft" => true,
                                  "baseRefName" => "main" }])

      out, err, status, lines = run_ship(dir, extra_env: { "GH_PR_LIST_JSON" => existing },
                                              show_json: recorded, moved_json: recorded)

      assert status.success?, "resume must complete, got:\n#{err}\n#{out}"
      assert_includes markers(lines), "FAST #{SLUG}", "the pre-flight runs on every ship — it recorded nothing to skip on"
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

  # --- cheap refusals come BEFORE the push (/tasks/submit-checks-before-push) -------
  #
  # 0/8 asks bin/dor-check --precheck (every merge-gate rule but the CI read) before
  # anything is committed; 2/8 runs bin/fast-check after the commit and BEFORE the
  # push, and a red there stops it. Neither is the verdict — 7/8's dor-check on a
  # settled CI still is — they only stop a push CI would turn red.

  # [unit] The order: pre-check first, then the pre-flight on a tree origin has not
  # seen (the stub's third column reads "unpushed"), then the PR, then the verdict.
  def test_the_pre_check_and_the_pre_flight_run_before_anything_is_pushed
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir)

      assert status.success?, err
      seq = markers(lines)
      assert_equal "PRECHECK #{SLUG}", seq[1], "the pre-check is the first gate call, after the task read"
      assert_equal [SLUG, "--precheck"], lines[1][1, 2]
      fast = lines.find { |l| l[0] == "FAST" }
      assert_equal "unpushed", fast[2], "the pre-flight must run before origin/#{BRANCH} exists"
      create_at = lines.index { |l| l[0] == "GH" && l[2] == "create" }
      assert lines.index(fast) < create_at, "the pre-flight runs before the PR is opened"
      assert seq.index("DOR #{SLUG}") > create_at, "the verdict still runs after the PR, on CI"
      assert err.index("0/8 pre-check — ") < err.index("1/8 commit — "), "the pre-check precedes the commit"
      assert err.index("2/8 pre-flight — ") < err.index("3/8 push — "), "the pre-flight precedes the push"
    end
  end

  def test_a_refused_pre_check_stops_before_the_commit_and_the_push
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "FAIL_PRECHECK" => "1" })

      refute status.success?, "a refused pre-check must stop the submit"
      assert_includes err, "the DoR pre-check refused"
      assert_includes err, "Nothing was committed or pushed."
      refute_empty `git -C #{dir} status --porcelain`.strip, "nothing was committed"
      `git -C #{dir} rev-parse --verify --quiet origin/#{BRANCH}`
      refute $?.success?, "nothing was pushed"
      refute_includes markers(lines), "FAST #{SLUG}", "no pre-flight ran"
      refute(lines.any? { |l| l[0] == "GH" }, "no PR call was made")
      refute_includes markers(lines), "DOR #{SLUG}", "the verdict never ran"
    end
  end

  # The repair seam skips the pre-check and nothing else: the 7/8 verdict still runs.
  def test_the_pre_check_repair_seam_skips_it_and_the_verdict_still_runs
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "SHIP_PRECHECK" => "off", "FAIL_PRECHECK" => "1" })

      assert status.success?, err
      assert_includes err, "0/8 pre-check — skipped (SHIP_PRECHECK=off)"
      refute_includes markers(lines), "PRECHECK #{SLUG}"
      assert_includes markers(lines), "DOR #{SLUG}", "the full verdict is not skipped with it"
    end
  end

  def test_a_red_pre_flight_stops_the_push
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "FAIL_FAST" => "1" })

      refute status.success?, "a red pre-flight must stop the push"
      assert_includes err, "the pre-flight is RED (exit 1) — nothing was pushed"
      assert_includes err, "--skip-preflight", "the override is named"
      `git -C #{dir} rev-parse --verify --quiet origin/#{BRANCH}`
      refute $?.success?, "the branch was NOT pushed"
      refute(lines.any? { |l| l[0] == "GH" && l[2] == "create" }, "no PR was opened")
      refute_includes markers(lines), "DOR #{SLUG}"
    end
  end

  def test_skip_preflight_pushes_past_a_red_pre_flight_and_ci_decides
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, args: [SLUG, "--skip-preflight"], extra_env: { "FAIL_FAST" => "1" })

      assert status.success?, err
      assert_includes err, "2/8 pre-flight — skipped (--skip-preflight); CI is the verdict."
      refute_includes markers(lines), "FAST #{SLUG}", "the pre-flight did not run"
      assert_includes markers(lines), "DOR #{SLUG}", "the verdict gate still did"
      assert_includes out, "stage: submitted (read back verified)"
    end
  end

  def test_the_pre_flight_can_be_skipped_by_env_and_the_verdict_is_still_dor_checks
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "SHIP_PREFLIGHT" => "off" })

      assert status.success?, err
      assert_includes err, "2/8 pre-flight — skipped (SHIP_PREFLIGHT=off)"
      refute_includes markers(lines), "FAST #{SLUG}", "the pre-flight did not run"
      assert_includes markers(lines), "DOR #{SLUG}", "the verdict gate still did"
    end
  end

  def test_a_green_pre_flight_says_ci_still_runs_the_full_suite
    with_repo do |dir|
      _out, err, status, = run_ship(dir)

      assert status.success?, err
      assert_includes err, "2/8 pre-flight — running bin/fast-check #{SLUG} before the push (nothing is recorded)"
      assert_includes err, "2/8 pre-flight — green. CI still runs the full suite on the PR."
    end
  end

  # An unlaunchable pre-flight is a red one: it stops the push and names the override.
  def test_a_missing_pre_flight_runner_stops_the_push_and_names_the_override
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "SHIP_FAST_CHECK_BIN" => "/nonexistent/fast-check" })

      refute status.success?
      assert_includes err, "the pre-flight is RED"
      assert_includes err, "--skip-preflight"
      refute_includes markers(lines), "DOR #{SLUG}"
    end
  end

  # A resumed submit (after a CI timeout, say) has nothing new to push, so it does not
  # re-run a pre-flight on a tree that already went out.
  def test_a_resumed_submit_with_nothing_new_to_push_skips_the_pre_flight
    with_repo do |dir|
      _out, err, status, = run_ship(dir)
      assert status.success?, err
      File.delete(File.join(dir, "stub.log"))

      _out, err, status, lines = run_ship(dir)

      assert status.success?, err
      assert_match(/2\/8 pre-flight — skipped: HEAD \h{12} is already pushed/, err)
      refute_includes markers(lines), "FAST #{SLUG}"
      assert_includes markers(lines), "PRECHECK #{SLUG}", "the pre-check still runs: it costs a second"
    end
  end

  # --- one board token per ship ------------------------------------------------
  #
  # Every child board CLI mints its own bearer unless one is handed down in
  # AGENT_API_TOKEN. A ship spawns seven or more such calls, so it mints once and
  # exports the token. These drive the REAL mint against a stub board and read the
  # token back OUT OF EACH CHILD'S ENVIRONMENT, which is the only thing that shows
  # the handoff reached the calls rather than merely being minted.

  def test_one_board_token_is_minted_per_ship_and_handed_to_every_board_call
    with_repo do |dir|
      with_stub_board(token: "tok-ship-1") do |port, requests|
        _out, err, status, lines = run_ship(dir, extra_env: { "TASK_API_BASE" => "http://127.0.0.1:#{port}" })

        assert status.success?, err
        assert_includes err, "one board token minted for this run"
        mints = requests.select { |r| r[:path] == "/api/v1/auth" }
        assert_equal 1, mints.size, "the ship mints exactly once"
        assert_equal({ "secret" => "test-secret" }, JSON.parse(mints.first[:body]), "with the secret chain's answer")

        seen = tokens_seen(dir)
        board_calls = seen.select { |marker, _| %w[TASK DOR].include?(marker) }
        assert_operator board_calls.size, :>=, 5, "a ship makes several board calls:\n#{markers(lines).join(', ')}"
        assert_equal ["tok-ship-1"], board_calls.map(&:last).uniq,
                     "every board call must carry the ONE token the ship minted"
      end
    end
  end

  def test_a_failed_mint_leaves_each_board_call_to_mint_its_own_and_never_stops_the_ship
    with_repo do |dir|
      # The harness default: the board is unroutable, so the up-front mint cannot
      # succeed. The ship must say so and carry on; the children see NO token and
      # fall back to their own secret chain, exactly as before the seam existed.
      _out, err, status, = run_ship(dir)

      assert status.success?, "a failed mint is a saving lost, never a refusal: #{err}"
      assert_includes err, "each board call mints its own"
      refute_includes err, "one board token minted"
      assert_equal [""], tokens_seen(dir).map(&:last).uniq, "no child may see a token the ship never minted"
    end
  end

  def test_a_token_handed_to_the_ship_is_reused_and_not_re_minted
    with_repo do |dir|
      with_stub_board(token: "tok-fresh") do |port, requests|
        _out, err, status, = run_ship(dir, extra_env: {
          "TASK_API_BASE" => "http://127.0.0.1:#{port}", "AGENT_API_TOKEN" => "tok-parent"
        })

        assert status.success?, err
        assert_includes err, "reusing the board token handed in"
        assert_empty requests.select { |r| r[:path] == "/api/v1/auth" }, "a handed token is never re-minted"
        assert_equal ["tok-parent"], tokens_seen(dir).map(&:last).uniq
      end
    end
  end

  # [marker, token] per child board CLI call, in call order.
  def tokens_seen(dir)
    path = File.join(dir, "stub-tokens.log")
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).map { |l| l.split("\t", 2).then { |m, t| [m, t.to_s] } }
  end

  # A one-connection-at-a-time stub board that answers every request with a mint
  # and records what it was asked. Only POST /api/v1/auth reaches it from a ship:
  # every other board call goes through the TASK/DOR stubs, which never dial out.
  # `logout_code` is the board's answer to the desk's logout (DELETE
  # /api/v1/agent_sessions/current); every other request gets the mint.
  def with_stub_board(token:, logout_code: 200)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new do
      loop do
        client = server.accept
        line = client.gets
        (client.close; next) if line.nil?

        method, path, = line.split(" ")
        headers = {}
        while (h = client.gets) && h != "\r\n"
          k, v = h.split(":", 2)
          headers[k.strip.downcase] = v.strip if v
        end
        body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
        requests << { method: method, path: path, body: body, auth: headers["authorization"] }
        code = method == "DELETE" ? logout_code : 200
        payload = JSON.generate(method == "DELETE" ? { "data" => { "session" => {} } } : { "token" => token })
        client.write("HTTP/1.1 #{code} OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
        client.close
      end
    rescue IOError, Errno::EBADF, Errno::ECONNRESET
      nil
    end
    yield port, requests
  ensure
    server&.close
    thread&.join(1)
  end

  # --- the desk's board login ends at `submitted` (DeskSession.logout) ----------
  # A login left in the desk was presented by the reviewer subagent of the same
  # harness, which the board refused on the move to `reviewed`.

  def keep_desk_login(dir, slug: SLUG)
    DeskSession.write(dir, { "slug" => "sess-desk", "task_slug" => slug, "token" => "tok-desk",
                             "expires_at" => (Time.now + 3600).utc.iso8601, "harness_session_id" => "h-1" })
  end

  def test_submit_logs_the_desk_out_once_the_task_is_submitted
    with_repo do |dir|
      keep_desk_login(dir)
      with_stub_board(token: "tok-ship") do |port, requests|
        out, err, status, lines = run_ship(dir, extra_env: { "TASK_API_BASE" => "http://127.0.0.1:#{port}" })

        assert status.success?, err
        assert_includes markers(lines), "TASK move", "the logout follows the move to submitted"
        logouts = requests.select { |r| r[:method] == "DELETE" }
        assert_equal ["/api/v1/agent_sessions/current"], logouts.map { |r| r[:path] }
        assert_equal "Bearer tok-desk", logouts.first[:auth], "the logout presents the desk's own login"
        refute File.exist?(DeskSession.path(dir)), "and the desk forgets it"
        assert_includes err, "logout — logged the desk out of #{SLUG}"
        refute_includes "#{out}#{err}", "tok-desk", "the token is never printed"
      end
    end
  end

  def test_a_refused_logout_warns_and_never_fails_the_submit
    with_repo do |dir|
      keep_desk_login(dir)
      with_stub_board(token: "tok-ship", logout_code: 500) do |port, _requests|
        out, err, status, = run_ship(dir, extra_env: { "TASK_API_BASE" => "http://127.0.0.1:#{port}" })

        assert status.success?, err
        assert_includes out, ShipWait::SUCCESS_LINE
        assert_match(/logout — the board did not revoke session sess-desk \(HTTP 500\).*warning only/, err)
        refute File.exist?(DeskSession.path(dir)), "forgotten locally even so"
      end
    end
  end

  def test_a_red_gate_keeps_the_desk_logged_in
    with_repo do |dir|
      keep_desk_login(dir)
      with_stub_board(token: "tok-ship") do |port, requests|
        _out, _err, status, = run_ship(dir, extra_env: { "TASK_API_BASE" => "http://127.0.0.1:#{port}",
                                                         "FAIL_DOR" => "1" })

        refute status.success?
        assert_empty requests.select { |r| r[:method] == "DELETE" }, "a task still building keeps its login"
        assert File.exist?(DeskSession.path(dir))
      end
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

  # [integration] On a RED CI the refusal says WHAT failed — the failing test and its
  # message, read from the failing job's log — so one fix pass covers it. The refusal
  # itself is unchanged: still dor-check's, still exit 1, still no move.
  def test_a_red_ci_refusal_prints_the_failing_tests_from_the_job_logs
    checks = JSON.generate([
      { "name" => "ci / rails (3)", "bucket" => "fail",
        "link" => "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/5/job/77" },
      { "name" => "ci / static", "bucket" => "pass", "link" => "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/5/job/78" }
    ])
    log = "2026-10-12T02:56:10.1Z Failure:\n" \
          "2026-10-12T02:56:10.1Z ThingTest#test_it_persists [test/models/thing_test.rb:9]:\n" \
          "2026-10-12T02:56:10.1Z Expected: 2\n2026-10-12T02:56:10.1Z   Actual: 1\n2026-10-12T02:56:10.1Z \n"
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "SHIP_CI_STATE" => "state:red", "FAIL_DOR" => "1",
                                                            "GH_PR_CHECKS_JSON" => checks, "GH_JOB_LOG" => log })

      refute status.success?
      assert_includes err, "what failed (from the failing jobs' logs"
      assert_includes err, "ci / rails (3)"
      assert_includes err, "✗ ThingTest#test_it_persists  [test/models/thing_test.rb:9]"
      assert_includes err, "Expected: 2"
      refute_includes err, "ci / static", "a passing job is not listed"
      assert_includes err, "fix every failure listed"
      refute(lines.any? { |l| l[0, 2] == %w[TASK move] })
    end
  end

  # A green CI that dor-check refuses for another reason prints no digest: there is no
  # failing job to read.
  def test_a_refusal_on_a_green_ci_prints_no_digest
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, extra_env: { "FAIL_DOR" => "1", "GH_PR_CHECKS_JSON" => "[]" })

      refute status.success?
      refute_includes err, "what failed"
      refute(lines.any? { |l| l[0] == "GH" && l[1, 2] == %w[pr checks] }, "no checks read on a green CI")
    end
  end

  # Guard catalog row 3.3: bin/task move verifies the stage write and the board derives
  # the PR url, so ship does not read either back. A failed --pr-url write is a note.
  def test_a_failed_pr_url_write_is_a_note_and_the_ship_moves_on
    with_repo do |dir|
      out, err, status, lines = run_ship(dir, extra_env: { "STUB_FAIL_TASK_UPDATE" => "1" })

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      assert_includes err, "the --pr-url write failed"
      assert(lines.any? { |l| l[0, 2] == %w[TASK move] }, "the move must still run")
      marks = markers(lines)
      assert marks.rindex("TASK show") < marks.index("TASK move"), "no read-back show after the move"
    end
  end

  # --- builder ownership + the build-stage seam --------------------------------
  # Ship hands off a BUILD: it must refuse a task that never walked the building
  # seam, and refuse a task a DIFFERENT live instance is building — both BEFORE
  # any side effect (commit/push/PR/move). The green-path tests above double as
  # the session-less degrade vector (the harness env is session-neutralized).

  # Guard catalog row 3.1: a designed task walks the building move itself, before the
  # first side effect, instead of being refused.
  def test_ship_walks_a_designed_task_to_building_before_committing
    with_repo do |dir|
      _out, err, status, lines = run_ship(dir, show_json: task_record(stage: "designed"))

      assert status.success?, err
      kinds = lines.map { |l| l[0, 3] }
      move_building = kinds.index(["TASK", "move", SLUG])
      assert move_building, "the building move must run"
      assert_equal "building", lines[move_building][3], "the first move is to building"
      assert_includes err, "0/8 claim"
      assert_equal "", `git -C #{dir} status --porcelain`.strip, "the run then commits as usual"
    end
  end

  # ── THE DESK IS THE BUILD CLAIM ─────────────────────────────────────────────
  #
  # Ship's holder pre-check follows the build gate's one rule (bin/lib/desk_claim.rb):
  # refuse only when a DIFFERENT live session's desk is bound to the task AND has
  # uncommitted changes. The desk lives under SHIP_PROJECTS_DIR; the shipping session
  # is CLAUDE_CODE_SESSION_ID.

  def test_ship_refuses_when_a_foreign_live_desk_has_uncommitted_work
    with_repo do |dir|
      desks = File.join(File.expand_path("..", dir), "desks")
      desk = FakeDesk.build(desks, task_slug: SLUG, session: "sess-rival-9999", dirty: true)
      _out, err, status, lines = run_ship(
        dir, extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111", "SHIP_PROJECTS_DIR" => desks }
      )

      refute status.success?, "shipping over another session's uncommitted desk must refuse"
      assert_includes err, desk, "the refusal must name the desk holding the work"
      assert_includes err, "uncommitted changes"
      assert_includes err, "bin/task begin #{SLUG} --steal", "the refusal must name the takeover path"
      assert_equal [%w[TASK show]], lines.map { |l| l[0, 2] }, "no step that writes may run past it"
      refute_equal "", `git -C #{dir} status --porcelain`.strip, "no commit may land"
    end
  end

  def test_ship_proceeds_when_the_foreign_desk_is_clean
    with_repo do |dir|
      desks = File.join(File.expand_path("..", dir), "desks")
      FakeDesk.build(desks, task_slug: SLUG, session: "sess-rival-9999", dirty: false)
      _out, err, status, = run_ship(
        dir, extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111", "SHIP_PROJECTS_DIR" => desks }
      )

      assert status.success?, "a clean foreign desk holds no work to lose, got:\n#{err}"
    end
  end

  def test_ship_proceeds_from_its_own_dirty_desk
    with_repo do |dir|
      desks = File.join(File.expand_path("..", dir), "desks")
      FakeDesk.build(desks, task_slug: SLUG, session: "sess-shipper-1111", dirty: true)
      _out, err, status, lines = run_ship(
        dir, extra_env: { "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111", "SHIP_PROJECTS_DIR" => desks }
      )

      assert status.success?, "the desk's own session must ship freely, got:\n#{err}"
      assert(lines.any? { |l| l[0, 2] == %w[TASK move] }, "the holder's ship must reach the move")
    end
  end

  # --- 5/8 record: the board derives the PR url (devops-v3 4c-i) ---------------

  # A record whose board serves `pr_url_or_derived` — the recorded url when there is
  # one, else the PR the board found on the task branch (and cached).
  def derived_record(stage:, derived:, recorded: nil)
    record = JSON.parse(task_record(stage: stage, pr_url: recorded))
    record["pr_url_or_derived"] = derived
    JSON.generate(record)
  end

  # [integration] The board already names the PR ship opened, so ship writes nothing
  # at 5/8, with the raw `devops.pr_url` still blank.
  def test_record_skips_the_write_when_the_board_derives_the_same_pr
    with_repo do |dir|
      out, err, status, lines = run_ship(
        dir,
        show_json: derived_record(stage: "building", derived: PR_URL),
        moved_json: derived_record(stage: "submitted", derived: PR_URL)
      )

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      refute(lines.any? { |l| l[0, 2] == %w[TASK update] }, "a pr_url the board derives must not be written")
      assert_includes out + err, "5/8 record — skipped: the board derives pr_url #{PR_URL}"
      assert_includes out, "PR: #{PR_URL}"
      assert_includes out, "stage: submitted (read back verified)"
    end
  end

  # [integration] The counterpart, so the skip above is not unconditional: a board
  # deriving a DIFFERENT PR (an older one on the same branch) is not the PR this run
  # opened, so ship records its own.
  def test_record_still_writes_when_the_board_derives_a_different_pr
    with_repo do |dir|
      other = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/42"
      out, err, status, lines = run_ship(
        dir,
        show_json: derived_record(stage: "building", derived: other),
        moved_json: derived_record(stage: "submitted", derived: PR_URL, recorded: PR_URL)
      )

      assert status.success?, "expected green ship, got:\n#{err}\n#{out}"
      assert_equal [SLUG, "--pr-url", PR_URL], lines.find { |l| l[0, 2] == %w[TASK update] }[2, 3]
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
      # Guard catalog row 3.4: the past-seam exit prints its own terminal line, which
      # bin/submit-wait reads as a success.
      assert_equal "stage: reviewed (past the submitted seam)", out.lines.last.strip
      assert_equal :succeeded, ShipWait.verdict(out, ended: true)
    end
  end

  def test_every_refusal_ends_on_the_not_submitted_terminal_line
    with_repo do |dir|
      out, _err, status, = run_ship(dir, extra_env: { "FAIL_DOR" => "1" })

      refute status.success?
      assert_equal "stage: building (not submitted)", out.lines.last.strip
      assert_equal :failed, ShipWait.verdict(out, ended: true)
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
  # task's own desk, and always has. It dies at the branch guard in bin/submit — which
  # is PRE-EXISTING, live on `main`, and untouched by this PR — because a detached
  # HEAD is not the task branch. There was never a regression here to restore, and
  # these tests assert the refusal, not a lane that does not exist.
  #
  # What the root-guard line in bin/submit does change is WHICH refusal you get. Without
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
      "AGENT_API_SECRET" => "test-secret", # the ship's own mint stops at ENV (see run_ship)
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
      # This is the one thing the bin/submit root-guard line changes, so it is asserted
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
  # SHIP DOES EMIT THE ROOT GUARD'S REFUSAL — on the one path where it cannot re-root.
  # A comment in bin/lib/fast_lane.rb once said the "refusing to certify it" text was
  # the cert writers' "and never ship's" (task handoff-narration-overclaims-four). With
  # NO desk on disk there is nothing to re-root to, so ship die!s with the assessment's
  # message — the same string bin/fast-check prints.
  def test_a_foreign_checkout_with_no_desk_dies_with_the_root_guard_refusal
    Dir.mktmpdir do |root|
      projects = File.realpath(root)
      stranger = File.join(projects, "myapp")
      FileUtils.mkdir_p(stranger)
      assert system("git -C #{stranger} init -q -b release")
      assert system("git -C #{stranger} config user.email t@t.co")
      assert system("git -C #{stranger} config user.name t")
      File.write(File.join(stranger, "README.md"), "hub\n")
      assert system("git -C #{stranger} add -A && git -C #{stranger} commit -q -m init")

      _out, err, status = run_ship_from(stranger, stranger, projects)

      refute status.success?, "no desk to re-root to — ship must refuse"
      assert_includes err, "refusing to run against it"
      refute_includes err, "re-rooting at the task worktree",
                      "with no desk on disk there is nothing to re-root to"
    end
  end

  # --- presence: the phase this run is in, published for peers to READ ---------
  #
  # THE DEFECT, measured on this box on 2026-09-01 with the slice-1 reader
  # (bin/agent-presence) pointed at a live machine: FIVE `bin/submit` groups, every
  # one at 0.0% CPU, all reported UNATTRIBUTED and the machine called BUSY. Four
  # were parked in a CI wait costing nothing; the fifth had spawned bin/fast-check
  # eleven seconds earlier and was about to take a core-set for ten minutes.
  # Nothing on disk told them apart, because the PROCESS NAME is identical in both
  # states — the check that usually gets this right is right by coincidence.
  #
  # These prove the writer half: the ship publishes WHICH state it is in, at the
  # boundaries it already prints, and the record is gradeable by a reader that
  # trusts nothing it says about being alive.

  def test_the_cert_phase_publishes_a_suite_claim_and_the_ci_wait_publishes_an_idle_one
    with_repo do |dir|
      snaps = File.join(dir, "..", "snaps")
      FileUtils.mkdir_p(snaps)

      # The CI wait is driven through the REAL CiStatus path (SHIP_CI_STATE unset)
      # so a stub runs INSIDE step 6/8 — the one phase no other stub can see, and
      # the exact phase the whole defect is about.
      ci_gh = File.join(dir, "ci-gh-stub")
      File.write(ci_gh, <<~SH)
        #!/bin/sh
        claims=$(cat "$CLAUDE_PROJECTS_DIR"/.agents/sessions/*.presence-* 2>/dev/null)
        printf '%s' "$claims" > "$PRESENCE_SNAP_DIR/CI.json"
        case "$2" in
          view) echo '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","baseRefName":"accepted"}' ;;
          checks) echo '[{"name":"CI","state":"SUCCESS","bucket":"pass"}]' ;;
          *) echo '{"total_count":1,"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}' ;;
        esac
      SH
      FileUtils.chmod("+x", ci_gh)

      _, err, status, = run_ship(dir, extra_env: {
        "PRESENCE_SNAP_DIR" => snaps,
        "SHIP_CI_STATE" => nil,
        "CI_STATUS_GH_BIN" => ci_gh,
        "CLAUDE_CODE_SESSION_ID" => "b41d7c02-0000-4000-8000-0123456789ab"
      })
      assert status.success?, "the run must still succeed: #{err}"

      cert = JSON.parse(File.read(File.join(snaps, "FAST.json")))
      ci = JSON.parse(File.read(File.join(snaps, "CI.json")))
      dor = JSON.parse(File.read(File.join(snaps, "DOR.json")))

      # THE DISTINCTION, on disk, at the two boundaries that matter.
      assert_equal ["working", "suite", "2/8 pre-flight"], cert.values_at("phase", "weight", "lane"),
                   "the pre-flight phase is the one that costs everything — it must say so"
      assert_equal ["waiting", "idle", "6/8 ci"], ci.values_at("phase", "weight", "lane"),
                   "the CI wait costs NOTHING, and reading it as a competing cert is the whole defect"
      assert_equal ["working", "light", "7/8 dor"], dor.values_at("phase", "weight", "lane")

      # It is the SAME claim moving, not three claims accumulating — otherwise a
      # reader would count one ship as three workloads.
      assert_equal 1, cert.fetch("pid").then { [cert, ci, dor].map { |c| c["pid"] }.uniq.size }
      assert_equal "ship", cert.fetch("kind")
      assert_equal SLUG, cert.fetch("task_slug")
      assert_equal "b41d7c02-0000-4000-8000-0123456789ab", cert.fetch("session_id")
    end
  end

  # The identity proof, end to end. Without it a reader holds a recyclable integer
  # and cannot tell our process from a stranger that inherited the number — which
  # is the failure that once made the orphan reaper kill a bystander.
  def test_the_published_claim_carries_the_OSs_start_time_for_a_live_pid
    with_repo do |dir|
      snaps = File.join(dir, "..", "snaps")
      FileUtils.mkdir_p(snaps)
      run_ship(dir, extra_env: { "PRESENCE_SNAP_DIR" => snaps })

      cert = JSON.parse(File.read(File.join(snaps, "FAST.json")))
      assert_operator cert.fetch("pid"), :>, 0
      refute_nil cert.fetch("pid_started_at"), "a claim with no start time proves nothing about itself"
      refute_empty cert.fetch("pid_started_at").to_s
      # BOTH subjects, for the reason the retired cert runlock carried both: the ship
      # can be killed while the cert it spawned survives in its group, and a
      # single-subject claim reports that worst case as dead.
      assert_operator cert.fetch("pgid"), :>, 0
      refute_empty cert.fetch("pgid_started_at").to_s
    end
  end

  # Clearing is an OPTIMIZATION. It runs on the graceful path so the surface stays
  # tidy — but correctness never depends on it, which is what the next test is for.
  def test_a_graceful_ship_leaves_no_claim_behind
    with_repo do |dir|
      _, err, status, = run_ship(dir)

      assert status.success?, err
      assert_empty presence_claims(dir), "a ship that exited cleanly must leave nothing to grade"
    end
  end

  # THE KILLED-WRITER RULE, asserted against a real SIGKILL — the constraint the
  # original ticket set, and the reason this is not a heartbeat: "a stale
  # cert-running file that never clears would make every future agent wait forever,
  # strictly worse than the grep it replaces."
  #
  # The answer is that the file's only claim to being live is a pid and a start
  # time the OS contradicts on the very next read. There is no timeout to elapse
  # and no renewal to miss, so THE WEDGE WINDOW IS ZERO. This kills a ship parked
  # in its cert phase and asserts both halves: the claim SURVIVES (so the workload
  # is still nameable) and the process it names is GONE (so any reader grades it a
  # corpse immediately).
  def test_a_KILLED_ship_leaves_a_claim_that_grades_as_a_corpse_on_the_next_read
    with_repo do |dir|
      slow_fast_check = File.join(dir, "slow-fast")
      File.write(slow_fast_check, "#!/bin/sh\nsleep 30\n")
      FileUtils.chmod("+x", slow_fast_check)

      pid = spawn_ship(dir, "SHIP_FAST_CHECK_BIN" => slow_fast_check)
      # Wait for the CERT phase specifically, not merely for a claim to exist. The
      # first claim appears at 1/8, where the ship is inside `git commit` — killing
      # it there strands a .git/HEAD.lock and the assertion becomes a race with the
      # tmpdir teardown rather than a statement about claims. Parked in the slow
      # stub, the kill lands where this test says it lands.
      claim = wait_for_claim(dir, lane: "2/8 pre-flight")
      Process.kill("KILL", pid)
      Process.wait(pid)

      assert_equal [claim], presence_claims(dir).map(&:last),
                   "a SIGKILLed writer leaves its claim behind, exactly as the cert runlock does"
      assert_equal "working", claim.fetch("phase")
      assert_equal pid, claim.fetch("pid"), "and it still NAMES the process, which is what makes it gradeable"
      refute alive?(claim.fetch("pid")),
             "the pid is gone, so a reader grades this a corpse on its very next read — no TTL to wait out"
    end
  end

  # Spawn ship detached with the same stubbed env run_ship builds, and return its
  # pid so the test can kill it. (run_ship blocks; a kill test cannot.)
  def spawn_ship(dir, overrides = {})
    log = File.join(dir, "stub.log")
    env = OutboundSeams.env({
      "SHIP_ROOT" => dir,
      "CLAUDE_PROJECTS_DIR" => presence_root(dir),
      "SHIP_TASK_BIN" => write_stub(dir, "task-stub", "TASK"),
      "SHIP_FAST_CHECK_BIN" => write_stub(dir, "fast-stub", "FAST"),
      "SHIP_DOR_CHECK_BIN" => write_stub(dir, "dor-stub", "DOR"),
      "SHIP_GH_BIN" => write_stub(dir, "gh-stub", "GH"),
      "SHIP_ACTIVITY_BIN" => write_stub(dir, "activity-stub", "ACTIVITY"),
      "STUB_LOG" => log,
      "AGENT_API_SECRET" => "test-secret", # the ship's own mint stops at ENV (see run_ship)
      "SHIP_CI_STATE" => "state:green",
      "TASK_SHOW_JSON" => task_record,
      "TASK_SHOW_JSON_MOVED" => task_record(stage: "submitted", pr_url: PR_URL)
    }.merge(overrides))
    Process.spawn(env, RbConfig.ruby, BIN, SLUG, out: File::NULL, err: File::NULL)
  end

  # Poll for the claim rather than sleeping a guessed interval: the assertion is
  # about the file's CONTENT, and a fixed sleep would make the test a race.
  def wait_for_claim(dir, timeout: 20, lane: nil)
    deadline = Time.now + timeout
    loop do
      found = presence_claims(dir).map(&:last).select { |c| lane.nil? || c["lane"] == lane }
      return found.first if found.any?
      raise "no presence claim#{lane && " at #{lane}"} appeared within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # --- 1/8 commit authorship (desk-commits-wrong-soul) ------------------------
  #
  # THE BEHAVIOUR PROOF for lib/commit_identity.rb. Its own unit tests drive the
  # module directly; these two run the REAL bin/submit and read the author back OUT
  # OF GIT, which is the only thing that shows the identity actually reached the
  # commit rather than merely being computed.
  #
  # with_repo sets a REPO-LEVEL `user.name tester` — the same shape as
  # turf-monster's "Steffon (Claude)" relic, and the identity that authored the
  # commit before this change.

  def test_ship_authors_its_commit_as_the_claiming_soul
    with_repo do |dir|
      _out, _err, status, = run_ship(dir, show_json: task_record(built_by: "shannon"))

      assert_predicate status, :success?
      assert_equal "shannon@mcritchie.studio", commit_author(dir, "%ae"),
                   "ship's 1/8 commit must be authored by the soul on the board, " \
                   "not by the repo's own git identity"
      assert_equal "Shannon", commit_author(dir, "%an")
      assert_equal "Shannon", commit_author(dir, "%cn"),
                   "the committer carries the soul too — leaving it would keep the " \
                   "relic on git log --format=%cn and leave half the provenance lying"
    end
  end

  def test_ship_does_not_fabricate_an_author_for_an_unattributed_task
    with_repo do |dir|
      _out, err, status, = run_ship(dir, show_json: task_record(built_by: nil))

      assert_predicate status, :success?
      assert_equal "tester", commit_author(dir, "%an"),
                   "with no soul on record the commit stays on the checkout's own " \
                   "identity — a guessed author is the defect, not the fix"
      assert_match(/names no builder/, err,
                   "and ship must SAY the commit is unattributed rather than pass silently")
    end
  end

  # The author of the commit ship just made, read out of git.
  def commit_author(dir, fmt)
    `git -C #{dir} log -1 --format=#{fmt}`.strip
  end
end
