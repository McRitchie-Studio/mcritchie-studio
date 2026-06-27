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

class ConductorTest < Minitest::Test
  BIN = File.expand_path("../../bin/conductor", __dir__)

  def setup
    @dir = Dir.mktmpdir("conductor-test")
    @fix = File.join(@dir, "fixtures")
    @log = File.join(@dir, "release-calls.log")
    FileUtils.mkdir_p(@fix)
    write_board
    write_fakes
    @env = {
      "TASK_BIN" => File.join(@dir, "task"),
      "RELEASE_BIN" => File.join(@dir, "release"),
      "REVIEWER_SELECT_BIN" => File.join(@dir, "reviewer-select"),
      "CURL_BIN" => File.join(@dir, "curl"),
      "RELEASE_CALL_LOG" => @log
    }
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- the standard board state shared by the tests ------------------------
  # submitted: feat-a (pipeline, mcritchie-studio) + rolio-x (non-pipeline)
  # reviewed:  feat-b (pipeline) + rolio-r (non-pipeline)
  # assembled: feat-c (pipeline, turf-monster, release_slug rel-2026-06-25-x)
  # building:  feat-d ; blocked: feat-e
  def write_board
    list("submitted", [["feat-a", "Feature A"], ["rolio-x", "Rolio thing"]])
    list("reviewed",  [["feat-b", "Feature B"], ["rolio-r", "Rolio review"]])
    list("assembled", [["feat-c", "Feature C"]])
    list("building",  [["feat-d", "Feature D"]])
    list("blocked",   [["feat-e", "Feature E"]])

    show("feat-a", stage: "submitted", title: "Feature A", repos: ["mcritchie-studio"])
    show("rolio-x", stage: "submitted", title: "Rolio thing", repos: ["rolio"])
    show("feat-b", stage: "reviewed", title: "Feature B", repos: ["mcritchie-studio"])
    show("rolio-r", stage: "reviewed", title: "Rolio review", repos: ["rolio"])
    show("feat-c", stage: "assembled", title: "Feature C", repos: ["turf-monster"],
                   release_slug: "rel-2026-06-25-x")
  end

  def list(stage, rows)
    body = rows.map { |slug, title| "#{slug}  [#{stage}]  #{title}" }.join("\n")
    File.write(File.join(@fix, "list-#{stage}.txt"), "#{body}\n(#{rows.size} task(s))\n")
  end

  def show(slug, stage:, title:, repos:, release_slug: nil)
    File.write(File.join(@fix, "show-#{slug}.json"), JSON.generate(
      "slug" => slug, "stage" => stage, "title" => title, "release_slug" => release_slug,
      "metadata" => { "devops" => { "repositories" => repos } }
    ))
  end

  def write_fakes
    # task: dispatch list/show against the fixtures dir.
    write_exec("task", <<~SH)
      #!/bin/bash
      FIX="#{@fix}"
      if [ "$1" = "list" ]; then f="$FIX/list-$3.txt"; [ -f "$f" ] && cat "$f"; exit 0; fi
      if [ "$1" = "show" ]; then f="$FIX/show-$2.json"; if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; exit 0; fi
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

  def run_conductor(*args)
    out, err, status = Open3.capture3(@env, RbConfig.ruby, BIN, *args)
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
    assert_includes out, "reviewed — merge queue"
    assert_includes out, "assembled — current release candidate"
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
    assert_includes out, "a script cannot render verdicts"
  end

  def test_plan_reviewed_recommends_release_merge_pipeline_only
    out, _err, _status = run_conductor("plan", "--no-health")

    assert_includes out, "reviewed → MERGE"
    assert_includes out, "bin/release merge feat-b"
    refute_includes out, "bin/release merge feat-b rolio-r",
      "the rolio (non-pipeline) reviewed task must not ride a mcritchie release merge"
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
    assert_includes out, "rolio-x"
    assert_includes out, "rolio-r"
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
    assert_includes out, "bin/release merge feat-b"
    assert_empty release_log, "merge without --run must not execute the merge"
  end

  def test_merge_run_invokes_release_merge_but_never_ship
    _out, _err, _status = run_conductor("merge", "--run")

    log = release_log
    assert_includes log, "merge feat-b", "merge --run forwards the reviewed pipeline slugs"
    refute_includes log, "rolio-r", "the non-pipeline reviewed task is excluded from the merge"
    refute_includes log, "ship", "merge --run must not ship"
  end

  def test_qa_dry_prints_prepare_without_invoking_release
    out, _err, status = run_conductor("qa")

    assert status.success?
    assert_includes out, "bin/release prepare"
    assert_empty release_log
  end
end
