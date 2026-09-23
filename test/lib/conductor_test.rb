# frozen_string_literal: true

# Standalone test for bin/conductor — the deterministic Build-and-Deploy cycle
# driver. No Rails needed: conductor shells out to bin/task / bin/release /
# bin/reviewer-select, so the test stubs those as fake binaries on a tmpdir and
# injects them via TASK_BIN / RELEASE_BIN / REVIEWER_SELECT_BIN (the same
# fake-binary-via-env pattern as test/lib/pr_status_test.rb's GH_BIN).
#
# Run directly:   ruby -Itest test/lib/conductor_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# The load-bearing assertion: conductor never ships implicitly. The fake
# `release` appends every call to RELEASE_CALL_LOG, so the tests can prove
# survey/plan/plain ship are dry while `ship --run` is the explicit autonomous
# production path.
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class ConductorTest < Minitest::Test
  BIN = File.expand_path("../../bin/conductor", __dir__)

  def setup
    @dir = Dir.mktmpdir("conductor-test")
    @fix = File.join(@dir, "fixtures")
    @log = File.join(@dir, "release-calls.log")
    FileUtils.mkdir_p(@fix)
    write_board
    write_fakes
    # SessionEnv.neutralized: the child must name NO agent session — bin/conductor
    # shells to session-reading bins. See test/support/session_env.rb.
    @env = SessionEnv.neutralized(
      "TASK_BIN" => File.join(@dir, "task"),
      "RELEASE_BIN" => File.join(@dir, "release"),
      "REVIEWER_SELECT_BIN" => File.join(@dir, "reviewer-select"),
      "CURL_BIN" => File.join(@dir, "curl"),
      "RELEASE_CALL_LOG" => @log
    )
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- the standard board state shared by the tests ------------------------
  # submitted: feat-a (pipeline, mcritchie-studio) + rolio-x (pipeline) + client-x (non-pipeline)
  # reviewed:  feat-b (pipeline) + rolio-r (pipeline) + client-r (non-pipeline)
  # assembled: feat-c (pipeline, turf-monster, release_slug rel-2026-06-25-x)
  # building:  feat-d (clean) + feat-e (a LIVE block — blocked_at set; the derived
  #            needs-attention list, since blocked is a building attribute now)
  def write_board
    list("submitted", [["feat-a", "Feature A"], ["rolio-x", "Rolio thing"], ["client-x", "Client thing"]])
    list("reviewed",  [["feat-b", "Feature B"], ["rolio-r", "Rolio review"], ["client-r", "Client review"]])
    list("assembled", [["feat-c", "Feature C"]])
    list("building",  [["feat-d", "Feature D"], ["feat-e", "Feature E"]])

    show("feat-a", stage: "submitted", title: "Feature A", repos: ["mcritchie-studio"])
    show("rolio-x", stage: "submitted", title: "Rolio thing", repos: ["rolio"])
    show("client-x", stage: "submitted", title: "Client thing", repos: ["client-app"])
    show("feat-b", stage: "reviewed", title: "Feature B", repos: ["mcritchie-studio"])
    show("rolio-r", stage: "reviewed", title: "Rolio review", repos: ["rolio"])
    show("client-r", stage: "reviewed", title: "Client review", repos: ["client-app"])
    show("feat-c", stage: "assembled", title: "Feature C", repos: ["turf-monster"],
                   release_slug: "rel-2026-06-25-x")
    show("feat-d", stage: "building", title: "Feature D", repos: ["mcritchie-studio"])
    # feat-e is a `building` task carrying a live block (blocked_at set).
    show("feat-e", stage: "building", title: "Feature E", repos: ["mcritchie-studio"],
                   blocked_at: "2026-07-11T12:00:00Z")
  end

  def list(stage, rows)
    body = rows.map { |slug, title| "#{slug}  [#{stage}]  #{title}" }.join("\n")
    File.write(File.join(@fix, "list-#{stage}.txt"), "#{body}\n(#{rows.size} task(s))\n")
  end

  def show(slug, stage:, title:, repos:, release_slug: nil, blocked_at: nil)
    File.write(File.join(@fix, "show-#{slug}.json"), JSON.generate(
      "slug" => slug, "stage" => stage, "title" => title, "release_slug" => release_slug,
      "blocked_at" => blocked_at,
      "metadata" => { "devops" => { "repositories" => repos } }
    ))
  end

  def write_fakes
    # task: dispatch list/show against the fixtures dir.
    # TASK_LIST_EXIT / TASK_SHOW_EXIT stand in for a board bin/task could not read:
    # a 301 from the canonical-host middleware, an expired agent credential, an
    # outage. bin/task dies on stderr and exits non-zero for all three, and this
    # fake reproduces exactly that shape (a message on STDERR, nothing on stdout).
    # TASK_SHOW_EXIT=4 is its EXIT_TASK_NOT_FOUND: the board ANSWERED, negatively.
    write_exec("task", <<~SH)
      #!/bin/bash
      FIX="#{@fix}"
      if [ "$1" = "list" ]; then
        if [ -n "$TASK_LIST_EXIT" ] && [ "$TASK_LIST_EXIT" != "0" ]; then
          echo "task: GET /api/v1/tasks?stage=$3 -> 301: (redirected to https://mcritchie.studio/)" >&2
          exit "$TASK_LIST_EXIT"
        fi
        f="$FIX/list-$3.txt"; [ -f "$f" ] && cat "$f"; exit 0
      fi
      if [ "$1" = "show" ]; then
        if [ -n "$TASK_SHOW_EXIT" ] && [ "$TASK_SHOW_EXIT" != "0" ]; then
          echo "task: GET /api/v1/tasks/$2 -> 401: (the board refused this credential)" >&2
          exit "$TASK_SHOW_EXIT"
        fi
        if [ -n "$TASK_SHOW_GARBAGE" ]; then echo 'not json at all'; exit 0; fi
        f="$FIX/show-$2.json"; if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; exit 0
      fi
      exit 0
    SH
    # release: record every call so the tests can prove ship is never invoked.
    write_exec("release", <<~SH)
      #!/bin/bash
      echo "$*" >> "$RELEASE_CALL_LOG"
      echo "release-fake: $*"
      exit 0
    SH
    # reviewer-select --json: canned primary+light pair.
    write_exec("reviewer-select", <<~SH)
      #!/bin/bash
      echo '{"reviewers":[{"slug":"carl"},{"slug":"shannon"}]}'
      exit 0
    SH
    # curl -w %{http_code}: pretend prod is healthy.
    write_exec("curl", <<~SH)
      #!/bin/bash
      printf '200'
      exit 0
    SH
  end

  def write_exec(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def run_conductor(*args, env: {})
    out, err, status = Open3.capture3(@env.merge(env), RbConfig.ruby, BIN, *args)
    [out, err, status]
  end

  def release_log
    File.exist?(@log) ? File.read(@log) : ""
  end

  # --- survey: enumerates EVERY stage + names the candidate ----------------

  def test_survey_enumerates_each_deploy_and_context_stage
    out, _err, status = run_conductor("survey", "--no-health")

    assert status.success?
    # Every stage block appears with its blurb.
    assert_includes out, "submitted — review intake"
    assert_includes out, "reviewed — sweep queue"
    assert_includes out, "assembled — QA-green release candidate"
    assert_includes out, "building — Build half"
    assert_includes out, "blocked — needs attention"
    # The actual tasks are listed (per-stage, not the flat list).
    assert_includes out, "feat-a"
    assert_includes out, "feat-b"
    assert_includes out, "feat-c"
    assert_includes out, "feat-d"
    assert_includes out, "feat-e"
  end

  def test_survey_reports_active_candidate_and_members
    out, _err, _status = run_conductor("survey", "--no-health")

    assert_includes out, "Active release candidate: rel-2026-06-25-x"
    assert_includes out, "members (1): feat-c"
  end

  def test_survey_default_command_is_survey
    out, _err, status = run_conductor("--no-health")

    assert status.success?
    assert_includes out, "Build-and-Deploy survey"
  end

  def test_survey_never_invokes_release
    run_conductor("survey", "--no-health")

    assert_empty release_log, "survey must be read-only — it must never call bin/release"
  end

  def test_survey_health_line_uses_curl_stub
    out, _err, status = run_conductor("survey") # health ON, CURL_BIN stub returns 200

    assert status.success?
    assert_includes out, "prod https://mcritchie.studio → ok (200)"
  end

  # --- plan: the correct next deterministic action per stage ---------------

  def test_plan_submitted_recommends_reviewer_select
    out, _err, status = run_conductor("plan", "--no-health")

    assert status.success?
    assert_includes out, "submitted → REVIEW"
    assert_includes out, "bin/reviewer-select feat-a"
    assert_includes out, "bin/reviewer-select rolio-x"
    refute_includes out, "bin/reviewer-select client-x"
    assert_includes out, "a script cannot render verdicts"
  end

  def test_plan_reviewed_recommends_release_merge_pipeline_only
    out, _err, _status = run_conductor("plan", "--no-health")

    assert_includes out, "reviewed → SWEEP"
    assert_includes out, "bin/release merge feat-b rolio-r"
    refute_includes out, "bin/release merge feat-b rolio-r client-r",
      "the client app (non-pipeline) reviewed task must not ride a release merge"
  end

  def test_plan_assembled_recommends_prepare_then_ship_choices
    out, _err, _status = run_conductor("plan", "--no-health")

    assert_includes out, "assembled → QA then SHIP"
    assert_includes out, "bin/release prepare"
    assert_includes out, "QA workflow handoff: bin/release ship --by conductor"
    assert_includes out, "autonomous workflow: bin/conductor ship --run"
  end

  def test_plan_flags_blocked_and_non_pipeline_separately
    out, _err, _status = run_conductor("plan", "--no-health")

    assert_includes out, "blocked → needs attention"
    assert_includes out, "feat-e"
    assert_includes out, "non-pipeline → not a mcritchie release member"
    assert_includes out, "client-x"
    assert_includes out, "client-r"
    refute_includes out, "rolio-x  Rolio thing  [rolio]"
    refute_includes out, "rolio-r  Rolio review  [rolio]"
  end

  def test_plan_reviewers_flag_previews_the_picked_pair
    out, _err, _status = run_conductor("plan", "--reviewers", "--no-health")

    assert_includes out, "picked: carl (primary) + shannon (light)"
  end

  def test_plan_never_invokes_release
    run_conductor("plan", "--reviewers", "--no-health")

    assert_empty release_log, "plan must be read-only — it must never call bin/release"
  end

  # --- the load-bearing gate: ship is explicit, never implicit -------------

  def test_ship_dry_prints_command_without_invoking_release
    out, _err, status = run_conductor("ship")

    assert status.success?
    assert_includes out, "bin/release ship --by conductor"
    assert_includes out, "dry"
    assert_empty release_log, "plain conductor ship must not execute production deploy"
  end

  def test_ship_run_invokes_autonomous_release_ship
    _out, _err, status = run_conductor("ship", "--run")

    assert status.success?
    assert_includes release_log, "ship --by conductor --yes",
      "ship --run forwards the explicit autonomous production ship command"
  end

  # --- drive subcommands: dry by default, only --run executes --------------

  def test_merge_dry_prints_command_without_invoking_release
    out, _err, status = run_conductor("merge")

    assert status.success?
    assert_includes out, "bin/release merge feat-b rolio-r"
    assert_empty release_log, "merge without --run must not execute the merge"
  end

  def test_merge_run_invokes_release_merge_but_never_ship
    _out, _err, _status = run_conductor("merge", "--run")

    log = release_log
    assert_includes log, "merge feat-b rolio-r", "merge --run forwards the reviewed pipeline slugs"
    refute_includes log, "client-r", "the non-pipeline reviewed task is excluded from the merge"
    refute_includes log, "ship", "merge --run must not ship"
  end

  def test_qa_dry_prints_prepare_without_invoking_release
    out, _err, status = run_conductor("qa")

    assert status.success?
    assert_includes out, "bin/release prepare"
    assert_empty release_log
  end

  # --- A FAILED READ IS NOT AN EMPTY ONE -----------------------------------
  #
  # THE DEFECT THESE PIN (filed 2026-09-20, verified at its lines 2026-09-22).
  # Every read here was `out, ok = run_bin(...)` + `return [] unless ok`, and
  # run_bin discarded the child's stderr. bin/task exits 1 on ANY non-2xx, so a
  # 301, a 401 or an outage turned every stage into an empty array: the survey
  # printed "(none)" under every stage, "Active release candidate: none" and
  # "blocked (0)", EXITED 0, and never mentioned the board. This is the false
  # all-clear bin/task's own archived-scan alarm exists to remove, rendered by
  # the tool an operator opens Step 0 with.

  def test_a_failed_stage_list_exits_non_zero
    _out, _err, status = run_conductor("survey", "--no-health", env: { "TASK_LIST_EXIT" => "1" })

    refute_predicate status, :success?,
                     "a board read that FAILED must not render as a survey that exits 0"
  end

  def test_a_failed_stage_list_never_prints_an_empty_pipeline
    out, _err, _status = run_conductor("survey", "--no-health", env: { "TASK_LIST_EXIT" => "1" })

    refute_includes out, "(none)"
    refute_includes out, "Active release candidate: none"
  end

  # The child already produced the diagnosis. Throwing it away is what sent an
  # operator into 1Password for a 301 (the incident behind bin/lib/board_read.rb).
  def test_a_failed_stage_list_carries_the_childs_diagnosis
    _out, err, _status = run_conductor("survey", "--no-health", env: { "TASK_LIST_EXIT" => "1" })

    assert_includes err, "the submitted stage list failed"
    assert_includes err, "301"
    assert_includes err, "redirected to"
  end

  # show_task double-swallowed: `ok ? (JSON.parse(out) rescue {}) : {}`. The {} it
  # returned made task_blocked? false for EVERY task and non_pipeline? treat every
  # task as a pipeline member.
  def test_a_failed_task_show_exits_non_zero
    _out, err, status = run_conductor("survey", "--no-health", env: { "TASK_SHOW_EXIT" => "1" })

    refute_predicate status, :success?
    assert_includes err, "401"
  end

  # The OTHER half of the same swallow: a read that succeeded and cannot be
  # parsed is an unreadable answer, not an empty one.
  def test_an_unparseable_task_show_exits_non_zero
    _out, err, status = run_conductor("survey", "--no-health", env: { "TASK_SHOW_GARBAGE" => "1" })

    refute_predicate status, :success?
    assert_includes err, "unparseable"
  end

  # THE FALSE-ALARM DIRECTION, which matters just as much. bin/task exit 4 is
  # EXIT_TASK_NOT_FOUND — the board POSITIVELY answered "there is no such task".
  # A slug archived between the stage list and its show is a race, not an outage,
  # and refusing it would wedge the survey on an ordinary board event.
  def test_a_task_the_board_says_is_gone_does_not_kill_the_survey
    out, err, status = run_conductor("survey", "--no-health", env: { "TASK_SHOW_EXIT" => "4" })

    assert_predicate status, :success?
    assert_includes out, "Build-and-Deploy survey"
    assert_includes err, "has no task"
  end

  # A mis-resolved binary never runs at all (Errno::ENOENT). That used to warn and
  # degrade to an empty stage; it is a failed read like any other.
  def test_a_task_binary_that_cannot_launch_exits_non_zero
    _out, err, status = run_conductor("survey", "--no-health",
                                      env: { "TASK_BIN" => File.join(@dir, "no-such-binary") })

    refute_predicate status, :success?
    assert_includes err, "the command never ran"
  end

  # The fix reaches a SECOND and more dangerous path: `conductor merge` read the
  # reviewed stage the same way and printed "no reviewed pipeline tasks to merge".
  def test_a_failed_read_does_not_render_merge_as_nothing_to_do
    out, _err, status = run_conductor("merge", env: { "TASK_LIST_EXIT" => "1" })

    refute_predicate status, :success?
    refute_includes out, "no reviewed pipeline tasks to merge"
  end

  # The exit code conductor calls "the board answered, negatively" must be
  # bin/task's own. A drift turns an archived slug back into a survey-killing
  # outage, and nothing else in the tree would notice.
  def test_the_not_found_exit_code_matches_bin_task
    conductor = File.read(BIN)[/^TASK_NOT_FOUND_EXIT = (\d+)/, 1]
    task = File.read(File.expand_path("../../bin/task", __dir__))[/^EXIT_TASK_NOT_FOUND = (\d+)/, 1]

    refute_nil conductor, "bin/conductor must pin the not-found exit code by name"
    refute_nil task, "bin/task must still define EXIT_TASK_NOT_FOUND"
    assert_equal task, conductor
  end

  # The reviewer preview is DELIBERATELY still advisory, and the difference is the
  # distinction this file now draws: it removes a "picked:" line from under a
  # command that prints regardless. Nothing is cleared, so nothing refuses.
  # AND IT DOES NOT DEGRADE IN SILENCE. This caller reads `run_bin` directly
  # rather than through `read_board`, so nothing else would surface the reason.
  def test_a_failed_reviewer_preview_says_why_on_stderr
    write_exec("reviewer-select", "#!/bin/bash\necho 'boom: no such task' >&2\nexit 1\n")
    _out, err, status = run_conductor("plan", "--reviewers", "--no-health")

    assert_predicate status, :success?
    assert_match(/reviewer preview for feat-a unavailable/, err)
    assert_match(/boom: no such task/, err, "the child diagnosed it; do not throw that away")
  end

  def test_a_failed_reviewer_preview_still_degrades
    write_exec("reviewer-select", "#!/bin/bash\nexit 1\n")
    out, _err, status = run_conductor("plan", "--reviewers", "--no-health")

    assert_predicate status, :success?
    assert_includes out, "bin/reviewer-select feat-a"
    refute_includes out, "picked:"
  end
end
