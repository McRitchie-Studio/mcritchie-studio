# frozen_string_literal: true

# Tests for bin/atomic-event — the agent's self-narration CLI (start/end an activity).
#
#   ruby -Itest test/lib/agent_activity_cli_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the pure helpers — argv parsing, session resolution, the local
#                 category guard — loaded in process (main is guarded so `load`
#                 is side-effect free).
#   [integration] the real script, shelled out against a localhost stub HTTP
#                 server, mints a token then POSTs the right open/close shape.

require "minitest/autorun"
require "minitest/mock"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"

load File.expand_path("../../bin/atomic-event", __dir__)

class AgentActivityCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/atomic-event", __dir__)
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  def cli(env = {})
    AgentActivityCli.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env))
  end

  # ── [unit] argv + session resolution ─────────────────────────────────────

  def test_unit_parse_flags_reads_double_dash_values
    flags = cli.parse_flags(%w[--category Explore --reason find issue])
    assert_equal "Explore", flags["category"]
    # A bare token after the value is not a flag — last --flag wins its next token.
    assert_equal "find", flags["reason"]
  end

  def test_unit_parse_flags_treats_a_flag_before_a_flag_as_boolean
    # `--clear --session X` must read clear=true + session=X, not clear="--session"
    # (the bug that made `heartbeat --clear --session X` target the wrong session).
    flags = cli.parse_flags(%w[--clear --session smoke])
    assert_equal true, flags["clear"], "a flag whose next token is another flag is boolean"
    assert_equal "smoke", flags["session"], "the following flag still parses its own value"
    # A trailing valueless flag is boolean too.
    assert_equal true, cli.parse_flags(%w[--reason go --clear])["clear"]
  end

  def test_unit_acting_agent_round_trip_write_read_clear
    Dir.mktmpdir do |proj|
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      assert_nil c.send(:read_acting_agent, SESSION), "no sticky agent by default"
      c.send(:write_acting_agent, SESSION, "steffon")
      assert_equal "steffon", c.send(:read_acting_agent, SESSION), "read-back returns the written soul"
      c.send(:clear_acting_agent, SESSION)
      assert_nil c.send(:read_acting_agent, SESSION), "clear removes the sticky agent"
    end
  end

  def test_unit_open_activity_marker_round_trip_and_clear
    Dir.mktmpdir do |proj|
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      # The CLI no longer holds a raw marker path at all (that was the footgun), so a
      # test that wants one reaches into SessionMarkers' private builder explicitly.
      path = SessionMarkers.send(:marker_path, SESSION, proj, ".open-activity")
      legacy = SessionMarkers.send(:marker_path, SESSION, proj, ".open-span")

      c.send(:write_open_activity, SESSION, 777)
      assert_equal "777", File.read(path).strip

      c.send(:record_open_activity, SESSION, stub_response("201 Created", "data" => { "id" => 888 }))
      assert_equal "888", File.read(path).strip

      c.send(:record_open_activity, SESSION, stub_response("500 Error", "error" => "boom"))
      assert_equal "888", File.read(path).strip, "failed open responses leave the last good marker intact"

      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, "999\n")
      c.send(:clear_open_activity, SESSION)
      refute File.exist?(path)
      refute File.exist?(legacy), "taxonomy-rename compatibility marker clears too"
    end
  end

  def test_unit_session_prefers_explicit_then_env
    assert_equal "flag-sid", cli.resolve_session_id("session" => "flag-sid")
    assert_equal "claude-sid",
                 cli("CLAUDE_CODE_SESSION_ID" => "claude-sid").resolve_session_id({})
    assert_equal "codex-sid",
                 cli("CODEX_THREAD_ID" => "codex-sid").resolve_session_id({})
    assert_equal "", cli.resolve_session_id({})
  end

  def test_unit_category_vocabulary_matches_the_model
    assert_equal %w[Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan],
                 AgentActivityCli::CATEGORIES
  end

  # ── [unit] resolve_marker: base mascot = session, task_slug/stage = desk ──

  def test_unit_resolve_marker_base_mascot_is_the_session_not_the_desk
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      # The bound task's DESK marker (.agent-context.json) carries the TASK's
      # builder mascot — the value that used to FLIP the base (Shellder→Sandshrew).
      write_context_marker(proj, "task_record_slug" => "desk-task",
                                 "mascot" => "sandshrew", "stage" => "reviewed")
      # The session marker carries the session's OWN Pokémon (its stable base).
      write_session_marker(proj, SESSION, "mascot" => "shellder")

      marker = Dir.chdir(proj) { cli("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(session_id: SESSION) }

      assert_equal "shellder", marker["mascot"], "base mascot = the session's OWN, never the desk/task builder mascot"
      assert_equal "desk-task", marker["task_slug"], "task_slug still describes the desk"
      assert_equal "reviewed", marker["stage"], "stage still describes the desk"
    end
  end

  def test_unit_resolve_marker_falls_back_to_desk_mascot_when_the_session_has_none
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      write_context_marker(proj, "task_record_slug" => "desk-task", "mascot" => "sandshrew")
      # No session-marker mascot → fall back to the desk so we never regress to nil.
      marker = Dir.chdir(proj) { cli("CLAUDE_PROJECTS_DIR" => proj).resolve_marker(session_id: SESSION) }

      assert_equal "sandshrew", marker["mascot"]
    end
  end

  # ── [unit] task_slug inference from a feat/<slug> branch ──────────────────
  # The MARKER fallback: with no desk/session task_slug, resolve_marker infers the
  # task from a `feat/<slug>` checkout branch so an activity is task-attributed even
  # before a task-bind write. (The `--task` flag is the explicit stamp — below.)

  def test_unit_task_slug_from_branch_reads_only_feat_branches
    c = cli
    slug = ->(branch) { c.send(:task_slug_from_branch, branch) }
    assert_equal "capture-and-deploy-attribution", slug.call("feat/capture-and-deploy-attribution")
    assert_equal "x", slug.call("feat/x")
    # A non-feature branch (a conductor on main/release) or a bare prefix is NOT a task.
    assert_nil slug.call("main")
    assert_nil slug.call("release")
    assert_nil slug.call("feature/foo")
    assert_nil slug.call("feat/")
    assert_nil slug.call("")
    assert_nil slug.call(nil)
  end

  def test_unit_resolve_marker_infers_task_from_the_feat_branch_when_markers_lack_one
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      # No desk marker, no session marker → task_slug would be blank; the feat branch
      # supplies it. Stub the git read so the test needs no real checkout.
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      c.define_singleton_method(:current_git_branch) { |_dir = nil| "feat/inferred-task" }

      marker = Dir.chdir(proj) { c.resolve_marker(session_id: SESSION) }
      assert_equal "inferred-task", marker["task_slug"], "the feat/<slug> branch fills a blank task_slug"
    end
  end

  def test_unit_resolve_marker_prefers_the_desk_slug_over_branch_inference
    Dir.mktmpdir do |proj|
      proj = File.realpath(proj)
      write_context_marker(proj, "task_record_slug" => "desk-task")
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      c.define_singleton_method(:current_git_branch) { |_dir = nil| "feat/inferred-task" }

      marker = Dir.chdir(proj) { c.resolve_marker(session_id: SESSION) }
      assert_equal "desk-task", marker["task_slug"], "an explicit desk slug wins over branch inference"
    end
  end

  # ── [unit] read_open_activity: the reader `action` pins rows with ─────────

  def test_unit_read_open_activity_round_trips_the_marker
    Dir.mktmpdir do |proj|
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      assert_nil c.send(:read_open_activity, SESSION), "no marker → nil (no span open)"
      c.send(:write_open_activity, SESSION, 42)
      assert_equal "42", c.send(:read_open_activity, SESSION), "reads back the id `start` wrote"
      c.send(:clear_open_activity, SESSION)
      assert_nil c.send(:read_open_activity, SESSION), "cleared → nil"
    end
  end

  # ── [integration] start POSTs an open activity ───────────────────────────

  def test_integration_start_mints_token_and_opens_activity
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                           "task_slug" => "narrated-trajectory-events", "mascot" => "caterpie", "stage" => "building")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason find-issue-with-api],
                         proj: proj)

      auth = requests.find { |r| r[:path] == "/api/v1/auth" }
      refute_nil auth, "expected a token mint"

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute_nil open, "expected a POST /api/v1/agent_activities"
      assert_equal "Bearer stub-token", open[:headers]["authorization"]

      body = JSON.parse(open[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "Explore", body["category"]
      assert_equal "find-issue-with-api", body["reason"]
      assert_equal "narrated-trajectory-events", body["task_slug"]
      assert_equal "caterpie", body["mascot"]
      assert_equal "building", body["stage"]
    end
  end

  def test_integration_start_records_the_open_activity_marker
    Dir.mktmpdir do |proj|
      run_cli(%W[start --session #{SESSION} --category Explore --reason find-issue-with-api], proj: proj)

      marker = File.join(proj, ".agents", "sessions", "#{SESSION}.open-activity")
      assert File.file?(marker), "start writes the local open-activity marker"
      assert_equal "1", File.read(marker).strip
    end
  end

  # ── [integration] --task stamps the activity's task explicitly ────────────
  # The observed fix: a session's FIRST activity is task-attributed immediately via
  # --task, instead of a blank TASK until a late `bin/task`/`bind-task` write.

  def test_integration_task_flag_stamps_task_slug_on_the_first_span
    Dir.mktmpdir do |proj|
      # No session/desk marker at all → without --task the task_slug is blank.
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason orient --task capture-and-deploy-attribution],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute_nil open, "expected a POST /api/v1/agent_activities"
      assert_equal "capture-and-deploy-attribution", JSON.parse(open[:body])["task_slug"],
                   "--task stamps the task on the very first activity"
    end
  end

  def test_integration_task_flag_overrides_the_marker_task_slug
    Dir.mktmpdir do |proj|
      # The marker says one task; --task explicitly overrides it for this activity.
      write_session_marker(proj, SESSION, "task_slug" => "marker-task", "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason orient --task explicit-task],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      body = JSON.parse(open[:body])
      assert_equal "explicit-task", body["task_slug"], "--task wins over the marker's task_slug"
      assert_equal "shellder", body["mascot"], "the base mascot still rides from the session marker"
    end
  end

  def test_integration_next_carries_the_task_flag_across_the_boundary
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[next --session #{SESSION} --outcome done --category Edit --reason go --task t-next],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      assert_equal "t-next", JSON.parse(open[:body])["task_slug"], "--task rides the boundary open too"
    end
  end

  def test_integration_end_posts_close_with_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[end --session #{SESSION} --outcome located-the-bug], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close" }
      refute_nil close, "expected a POST /api/v1/agent_activities/close"
      body = JSON.parse(close[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "located-the-bug", body["outcome"]
    end
  end

  def test_integration_end_clears_the_open_activity_marker
    Dir.mktmpdir do |proj|
      marker = seed_open_activity_marker(proj, SESSION, 1)
      legacy = seed_open_activity_marker(proj, SESSION, 2, legacy: true)

      run_cli(%W[end --session #{SESSION} --outcome located-the-bug], proj: proj)

      refute File.exist?(marker)
      refute File.exist?(legacy), "legacy open-span marker clears with the canonical marker"
    end
  end

  def test_integration_end_sends_the_explicit_agent_so_close_targets_that_lane
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[end --session #{SESSION} --outcome approve --agent carl], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close" }
      assert_equal "carl", JSON.parse(close[:body])["agent"], "--agent rides the close so it hits carl's lane"
    end
  end

  def test_integration_end_sends_measured_usage_from_the_open_activity_baseline
    Dir.mktmpdir do |proj|
      seed_open_activity_marker(proj, SESSION, 1)
      seed_activity_usage_baseline(proj, SESSION, 1,
                                   "input" => 1000, "output" => 0,
                                   "cache_creation" => 0, "cache_read" => 0)
      write_claude_transcript(
        proj, SESSION,
        "input_tokens" => 7000,
        "output_tokens" => 383,
        "cache_creation_input_tokens" => 200,
        "cache_read_input_tokens" => 304_000
      )

      requests = run_cli(%W[end --session #{SESSION} --outcome approved], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close" }
      body = JSON.parse(close[:body])
      assert_equal "claude-opus-4-8", body["model"]
      assert_equal 6200, body["tokens_in"], "activity display tokens exclude cache-read fallback"
      assert_equal 383, body["tokens_out"]
      assert_equal 304_000, body["cache_read_tokens"], "cache-read is kept only for cost"
      # (6000*5 + 383*25 + 200*5*2.0 + 304000*5*0.10)/1e6 = 0.193575; cache-write = 1h list rate.
      assert_in_delta 0.1936, body["cost"].to_f, 0.0001
    end
  end

  # ── [unit] concurrent same-session lanes report BLANK usage, not double-counts ──
  # The same-session reviewer-fanout blocker: usage is a per-session transcript
  # diff, so two lanes open at once can't be split — a per-lane close-diff would
  # double-count the other lane. Guard: opening a second lane taints EVERY
  # overlapping window so it reports NOTHING (measured_usage? false) — the honest
  # state — instead of a wrong-but-real-looking value. (Reviewers in SEPARATE
  # subagent sessions each keep their own transcript, so they still measure; see
  # the sole-lane measured-usage test above.)
  def test_unit_concurrent_same_session_lanes_report_blank_usage
    Dir.mktmpdir do |proj|
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      totals = { "input" => 5000, "output" => 100, "cache_creation" => 0, "cache_read" => 0 }
      result = AgentSessionUsage::Result.new(model: "claude-opus-4-8", totals: totals, delta: nil)

      # carl's lane opens first (sole → measurable), then shannon's opens while
      # carl is still open → the shared transcript can no longer be split per lane.
      c.stub(:capture_session_usage, result) do
        c.send(:seed_activity_usage_baseline, SESSION, "1", "carl")
        c.send(:seed_activity_usage_baseline, SESSION, "2", "shannon")
      end

      path = File.join(proj, ".agents", "sessions", "#{SESSION}.activity-usage.json")
      baselines = JSON.parse(File.read(path))
      assert_equal "carl", baselines["1"]["agent"], "the baseline map is now lane-aware"
      assert baselines["1"]["shared"], "the already-open lane is tainted when a concurrent lane opens"
      assert baselines["2"]["shared"], "the second lane opens into a shared window"

      # Both overlapping lanes report NOTHING — never a double-counted value.
      assert_empty c.send(:activity_usage_payload, SESSION, "1"), "carl's shared window reports no usage"
      assert_empty c.send(:activity_usage_payload, SESSION, "2"), "shannon's shared window reports no usage"
    end
  end

  # ── [integration] action self-reports an off-box row to the open activity ──
  # bin/release's deploy steps run as subprocesses the PostToolUse hook can't see;
  # `action` pins each to the open span (the marker) so the span shows real rows.

  def test_integration_action_reports_to_the_open_activity
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION,
                           "task_slug" => "deploy-spans-self-report-actions", "mascot" => "scyther", "stage" => "assembled")
      seed_open_activity_marker(proj, SESSION, 1) # the span bin/release opened

      requests = run_cli(%W[action --session #{SESSION} --summary qa-deploy-mcritchie-studio], proj: proj)

      post = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_actions" }
      refute_nil post, "action POSTs one agent_action"
      body = JSON.parse(post[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "1", body["agent_activity_id"], "pinned to the open activity from the marker"
      assert_equal "qa-deploy-mcritchie-studio", body["summary"]
      assert_equal "bash", body["kind"], "a deploy step is a shell op → the bash default"
      assert_equal "scyther", body["mascot"]
      assert_equal "assembled", body["stage"]
    end
  end

  def test_integration_action_without_an_open_activity_is_a_noop
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      # No open-activity marker (no span open) → nothing to attribute to → no POST,
      # and it never even mints a token (the marker check precedes the HTTP).
      requests = run_cli(%W[action --session #{SESSION} --summary orphan-step], proj: proj)
      assert_nil requests.find { |r| r[:path] == "/api/v1/agent_actions" }, "no open activity → action does not POST"
    end
  end

  def test_integration_action_with_explicit_kind_overrides_the_bash_default
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      seed_open_activity_marker(proj, SESSION, 9)
      requests = run_cli(%W[action --session #{SESSION} --summary verify-boot --kind verify], proj: proj)
      post = requests.find { |r| r[:path] == "/api/v1/agent_actions" }
      assert_equal "verify", JSON.parse(post[:body])["kind"]
    end
  end

  # A DISTILLED FINDING self-reports under the canonical `finding` verb so it reads
  # as "FINDING · <conclusion>" on the heartbeat — via the `--finding` shorthand or
  # an explicit `--kind finding`. Both must stamp kind=finding with the conclusion.
  def test_integration_action_finding_shorthand_stamps_the_finding_verb
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      seed_open_activity_marker(proj, SESSION, 7)
      requests = run_cli(
        %W[action --session #{SESSION} --summary paging-reads-are-plumbing --finding],
        proj: proj
      )
      body = JSON.parse(requests.find { |r| r[:path] == "/api/v1/agent_actions" }[:body])
      assert_equal "finding", body["kind"], "--finding shorthand resolves to the finding verb"
      assert_equal "paging-reads-are-plumbing", body["summary"]
    end
  end

  def test_integration_action_explicit_kind_finding_reads_as_a_finding
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      seed_open_activity_marker(proj, SESSION, 8)
      requests = run_cli(
        %W[action --session #{SESSION} --summary validate-then-resolve --kind finding],
        proj: proj
      )
      assert_equal "finding", JSON.parse(requests.find { |r| r[:path] == "/api/v1/agent_actions" }[:body])["kind"]
    end
  end

  def test_integration_action_forwards_idempotency_key_for_ci_ingestion
    # bin/ci-scope-capture sends ci:<pr>:<sha>:<job> so a re-read never doubles a
    # row; the verb must forward it into the POST body for capture to dedupe on.
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      seed_open_activity_marker(proj, SESSION, 3)
      requests = run_cli(
        %W[action --session #{SESSION} --summary ci-test --kind test_scope
           --event-slug ci_test --result-slug pass --idempotency-key ci:7:deadbeef:test],
        proj: proj
      )
      body = JSON.parse(requests.find { |r| r[:path] == "/api/v1/agent_actions" }[:body])
      assert_equal "ci:7:deadbeef:test", body["idempotency_key"]
      assert_equal "ci_test", body["event_slug"]
    end
  end

  def test_integration_action_omits_a_blank_idempotency_key
    # A plain action carries no key — it must be dropped, not sent as "".
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "task_slug" => "x")
      seed_open_activity_marker(proj, SESSION, 4)
      requests = run_cli(%W[action --session #{SESSION} --summary plain-step], proj: proj)
      body = JSON.parse(requests.find { |r| r[:path] == "/api/v1/agent_actions" }[:body])
      refute body.key?("idempotency_key"), "a blank idempotency_key must be dropped from the body"
    end
  end

  def test_integration_end_falls_back_to_the_sticky_heartbeat_agent
    Dir.mktmpdir do |proj|
      # a `<Soul> Heartbeat` sets the sticky; a later bare `end` must still close
      # that soul's lane, not the nil lane.
      run_cli(%W[heartbeat steffon --session #{SESSION}], proj: proj)
      requests = run_cli(%W[end --session #{SESSION} --outcome shipped], proj: proj)

      close = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close" }
      assert_equal "steffon", JSON.parse(close[:body])["agent"], "end inherits the sticky acting soul"
    end
  end

  # ── [integration] --agent stamps the acting soul on the activity ──────────

  def test_integration_start_stamps_agent_on_the_open_activity
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Edit --reason add-guard --agent avi], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute_nil open, "expected a POST /api/v1/agent_activities"
      body = JSON.parse(open[:body])
      assert_equal "avi", body["agent"], "--agent rides the open-activity POST"
      assert_equal "shellder", body["mascot"], "the base session mascot rides alongside, unchanged"
    end
  end

  def test_integration_start_stamps_supervisor_on_the_open_activity
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Verify --reason review --agent carl --supervisor avi],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      body = JSON.parse(open[:body])
      assert_equal "carl", body["agent"]
      assert_equal "avi", body["supervisor"], "supervisor attribution is explicit, not prose"
    end
  end

  def test_integration_next_carries_agent_across_the_boundary
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[next --session #{SESSION} --outcome done --category Edit --reason go --agent carl],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      assert_equal "carl", JSON.parse(open[:body])["agent"]
    end
  end

  def test_integration_start_without_agent_omits_the_key
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute JSON.parse(open[:body]).key?("agent"), "a bare start sends no agent key"
    end
  end

  # ── [integration] grade + awaiting — the agent grade-events flow ──────────

  def test_integration_grade_posts_disposition_slug_and_intent_to_the_activity
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[grade 42 --disposition not --slug noisy-activity --bank], proj: proj)

      grade = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/42/grade" }
      refute_nil grade, "grade POSTs to the activity grade endpoint"
      body = JSON.parse(grade[:body])
      assert_equal "not", body["disposition"]
      assert_equal "noisy-activity", body["slug"]
      assert_equal "bank", body["intent"], "--bank becomes intent=bank"
      refute body.key?("grader"), "the CLI never sends a grader — the server forces alex"
    end
  end

  def test_integration_grade_without_an_activity_id_posts_nothing
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[grade --disposition good], proj: proj)

      assert_empty requests.select { |r| r[:path].to_s.include?("/grade") }, "no activity id → no grade POST"
    end
  end

  def test_integration_awaiting_gets_the_endpoint_with_the_limit
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[awaiting --limit 5], proj: proj)

      fetch = requests.find { |r| r[:method] == "GET" && r[:path].start_with?("/api/v1/agent_activities/awaiting_grade") }
      refute_nil fetch, "awaiting GETs the awaiting_grade endpoint"
      assert_includes fetch[:path], "limit=5"
    end
  end

  # ── [integration] STICKY heartbeat agent — a `<Soul> Heartbeat` self-attributes ─

  def test_integration_heartbeat_sets_a_sticky_agent_a_bare_start_inherits
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      # `atomic-event heartbeat avi` sets the sticky (local, no HTTP)…
      run_cli(%W[heartbeat avi --session #{SESSION}], proj: proj)
      # …so a subsequent BARE start (no --agent) attributes the activity to avi.
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason orient], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      body = JSON.parse(open[:body])
      assert_equal "avi", body["agent"], "the bare start inherits the sticky heartbeat agent"
      assert_equal "shellder", body["mascot"], "base mascot stays the session's own; the soul stacks on top"
    end
  end

  def test_integration_explicit_agent_overrides_the_sticky
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      run_cli(%W[heartbeat avi --session #{SESSION}], proj: proj)
      # A delegated reviewer passes its OWN --agent — it must win over the sticky.
      requests = run_cli(%W[start --session #{SESSION} --category Delegate --reason review --agent carl], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      assert_equal "carl", JSON.parse(open[:body])["agent"], "explicit --agent overrides the sticky heartbeat agent"
    end
  end

  def test_integration_heartbeat_clear_stops_the_sticky_attribution
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      run_cli(%W[heartbeat avi --session #{SESSION}], proj: proj)
      run_cli(%W[heartbeat --clear --session #{SESSION}], proj: proj)
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute JSON.parse(open[:body]).key?("agent"), "after --clear a bare start sends no agent"
    end
  end

  def test_integration_session_end_clears_the_sticky_agent
    Dir.mktmpdir do |proj|
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      run_cli(%W[heartbeat avi --session #{SESSION}], proj: proj)
      # close-open (the SessionEnd hook) tears down the sticky so a later reuse of
      # this session id can't silently inherit it.
      run_cli(%W[close-open --session #{SESSION} --outcome done], proj: proj)
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute JSON.parse(open[:body]).key?("agent"), "session end cleared the sticky; the next start sends no agent"
    end
  end

  def test_integration_session_end_clears_the_open_activity_marker
    Dir.mktmpdir do |proj|
      marker = seed_open_activity_marker(proj, SESSION, 1)
      legacy = seed_open_activity_marker(proj, SESSION, 2, legacy: true)

      run_cli(%W[close-open --session #{SESSION} --outcome done], proj: proj)

      refute File.exist?(marker)
      refute File.exist?(legacy), "SessionEnd clears both activity marker names"
    end
  end

  # ── [integration] base mascot stays the session's own across a task bind ──

  def test_integration_base_mascot_stays_the_session_mascot_across_a_task_bind
    Dir.mktmpdir do |proj|
      # The session's OWN Pokémon (its stable base mascot)…
      write_session_marker(proj, SESSION, "mascot" => "shellder")
      # …and a bound task's DESK marker carrying the TASK's builder mascot — this
      # used to FLIP the base (the observed Shellder→Sandshrew switch). It must not.
      write_context_marker(proj, "task_record_slug" => "someone-elses-task",
                                 "mascot" => "sandshrew", "stage" => "reviewed")

      requests = run_cli(%W[start --session #{SESSION} --category Verify --reason review], proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      body = JSON.parse(open[:body])
      assert_equal "shellder", body["mascot"],
                   "base mascot stays the session's own, not the bound task's builder mascot"
      assert_equal "someone-elses-task", body["task_slug"],
                   "the desk task_slug is still recorded (builder mascot stays reachable via it)"
      assert_equal "reviewed", body["stage"], "stage still describes the desk"
    end
  end

  # ── [integration] BOUNDARY transition: next / start --outcome ────────────

  def test_integration_next_opens_with_prior_outcome_in_one_call
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[next --session #{SESSION} --outcome found-the-bug --category Edit --reason add-the-guard],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute_nil open, "next opens the new activity (carrying the prior outcome)"
      body = JSON.parse(open[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "Edit", body["category"]
      assert_equal "add-the-guard", body["reason"]
      assert_equal "found-the-bug", body["prior_outcome"], "the prior activity's outcome rides the SAME call"
    end
  end

  def test_integration_start_with_outcome_carries_prior_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --outcome wrapped-explore --category Edit --reason change-it],
                         proj: proj)

      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      body = JSON.parse(open[:body])
      assert_equal "wrapped-explore", body["prior_outcome"]
    end
  end

  def test_integration_start_without_outcome_omits_prior_outcome
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --category Explore --reason look], proj: proj)
      open = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities" }
      refute JSON.parse(open[:body]).key?("prior_outcome"), "a bare start sends no prior_outcome key"
    end
  end

  # ── [integration] session-end teardown: close-open ───────────────────────

  def test_integration_close_open_reads_session_from_stdin_and_posts_close_all
    Dir.mktmpdir do |proj|
      # The SessionEnd hook pipes its event JSON on stdin; no --session, no env id.
      requests = run_cli(%w[close-open], proj: proj, with_session_env: false,
                         stdin: JSON.generate("session_id" => SESSION, "reason" => "logout"))

      close_all = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close_all" }
      refute_nil close_all, "close-open posts to /api/v1/agent_activities/close_all"
      body = JSON.parse(close_all[:body])
      assert_equal SESSION, body["session_id"], "the session id comes from the stdin payload"
      assert_equal "session ended", body["outcome"], "defaults to a generic teardown outcome"
    end
  end

  def test_integration_close_open_accepts_codex_thread_id_from_stdin
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[close-open], proj: proj, with_session_env: false,
                         stdin: JSON.generate("thread_id" => SESSION, "reason" => "stop"))

      close_all = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close_all" }
      refute_nil close_all, "Codex Stop stdin should close open activities"
      assert_equal SESSION, JSON.parse(close_all[:body])["session_id"]
    end
  end

  def test_integration_close_open_respects_explicit_outcome_and_session_flag
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[close-open --session #{SESSION} --outcome wrapped-it-up], proj: proj)

      close_all = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/agent_activities/close_all" }
      body = JSON.parse(close_all[:body])
      assert_equal SESSION, body["session_id"]
      assert_equal "wrapped-it-up", body["outcome"]
    end
  end

  def test_integration_close_open_with_no_session_anywhere_hits_no_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[close-open], proj: proj, with_session_env: false, stdin: "")
      assert_empty requests, "no session id (flag / env / stdin) → nothing to close → no network"
    end
  end

  def test_integration_unknown_category_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%W[start --session #{SESSION} --category Vibe --reason nope], proj: proj)
      assert_empty requests, "a locally-invalid category must POST nothing"
    end
  end

  def test_integration_no_session_id_never_hits_the_network
    Dir.mktmpdir do |proj|
      requests = run_cli(%w[start --category Explore --reason x], proj: proj, with_session_env: false)
      assert_empty requests, "no session id → nothing to narrate → no network"
    end
  end

  def test_integration_always_exits_zero_even_when_endpoint_is_down
    Dir.mktmpdir do |proj|
      _out, _err, status = Open3.capture3(
        base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:1"),
        RbConfig.ruby, BIN, "start", "--session", SESSION, "--category", "Explore", "--reason", "x",
        chdir: proj
      )
      assert_equal 0, status.exitstatus, "the CLI must always exit 0"
    end
  end

  private

  def write_session_marker(projects_dir, session_id, attrs)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "#{session_id}.json"), JSON.generate(attrs))
  end

  def seed_open_activity_marker(projects_dir, session_id, id, legacy: false)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    suffix = legacy ? "open-span" : "open-activity"
    path = File.join(sessions, "#{session_id}.#{suffix}")
    File.write(path, "#{id}\n")
    path
  end

  def seed_activity_usage_baseline(projects_dir, session_id, activity_id, totals)
    sessions = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(sessions)
    path = File.join(sessions, "#{session_id}.activity-usage.json")
    File.write(path, JSON.generate(activity_id.to_s => totals))
    path
  end

  def write_claude_transcript(home_dir, session_id, usage)
    dir = File.join(home_dir, ".claude", "projects", "test-project")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    line = {
      "type" => "assistant",
      "uuid" => "turn-activity-usage",
      "message" => {
        "model" => "claude-opus-4-8",
        "usage" => usage
      }
    }
    File.write(path, "#{JSON.generate(line)}\n")
    path
  end

  # The worktree DESK marker (.agent-context.json) — carries the BOUND task's
  # context (task slug + its builder mascot). resolve_marker walks up from cwd to
  # find it, so tests write it at the proj dir they chdir into.
  def write_context_marker(dir, attrs)
    File.write(File.join(dir, ".agent-context.json"), JSON.generate(attrs))
  end

  # SessionEnv.neutralized: the child must name NO agent session unless a case opts
  # one in (it merges on top) — bin/atomic-event resolves session identity.
  # See test/support/session_env.rb.
  def base_env(projects_dir)
    SessionEnv.neutralized(
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_PROJECTS_DIR" => projects_dir,
      "HOME" => projects_dir
    )
  end

  # Shell out to the real CLI against a one-shot stub server; returns the recorded
  # requests. chdir into the isolated proj dir so no stray .agent-context.json up
  # the real tree leaks into the marker resolution.
  def run_cli(argv, proj:, with_session_env: true, stdin: nil)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests) }

    env = base_env(proj).merge("ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}")
    env["CLAUDE_CODE_SESSION_ID"] = SESSION if with_session_env && !argv.include?("--session")
    opts = { chdir: proj }
    opts[:stdin_data] = stdin unless stdin.nil?
    Open3.capture3(env, RbConfig.ruby, BIN, *argv, **opts)
    requests
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests)
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
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, headers: headers, body: body }

      status, payload = response_for(method, path)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(method, path)
    return ["200 OK", JSON.generate("token" => "stub-token", "expires_at" => (Time.now + 86_400).utc.iso8601)] if path == "/api/v1/auth"
    return ["201 Created", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/agent_activities"
    return ["201 Created", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/agent_actions"
    return ["200 OK", JSON.generate("data" => { "id" => 1 })] if method == "POST" && path == "/api/v1/agent_activities/close"
    return ["200 OK", JSON.generate("data" => { "closed" => 1 })] if method == "POST" && path == "/api/v1/agent_activities/close_all"
    if method == "POST" && path.match?(%r{\A/api/v1/agent_activities/\d+/grade\z})
      return ["201 Created", JSON.generate("data" => { "id" => 5, "grader" => "alex", "disposition" => "not",
                                                       "slug" => "noisy activity", "banked" => true })]
    end
    if method == "GET" && path.start_with?("/api/v1/agent_activities/awaiting_grade")
      return ["200 OK", JSON.generate("data" => [{ "id" => 7, "category" => "Verify",
                                                   "reason" => "review the diff", "outcome" => "approved" }])]
    end

    ["404 Not Found", JSON.generate("error" => "unexpected #{method} #{path}")]
  end

  def stub_response(code, body_hash)
    Struct.new(:code, :body).new(code, JSON.generate(body_hash))
  end

  # PUBLIC AGAIN — and this is not cosmetic. Everything below sat under the `private`
  # at the top of this helper section, and Minitest only collects PUBLIC `test_*`
  # methods. So the two sandbox integration tests below NEVER RAN: the suite reported
  # 53 green and silently skipped them, while the PR's checks_run cited them as the
  # proof that an unpinned spawn aborts. A test that cannot fail proves nothing, and a
  # count that does not notice its absence is how it goes unseen. The `private` above
  # still covers the helpers it was written for.
  public

  # --- [integration] the narration-marker sandbox (spawned-child vector) --------
  #
  # bin/atomic-event writes four markers into <projects>/.agents/sessions —
  # .acting-agent, .open-activity, .open-span, .activity-usage.json — and resolved
  # each by the CLAUDE_PROJECTS_DIR-else-real-projects-root FALLBACK. The tests in
  # this file pin the root, but that pinning is a CONVENTION: nothing failed
  # closed when a spawned child forgot. This is the assertion that it now does.
  #
  # `heartbeat` is the probe because it is LOCAL-only (no HTTP) — it writes
  # .acting-agent straight to disk, so the guard is the only thing between the
  # child and the operator's store. The unpinned case ABORTS before any IO, so
  # this never writes the real store even when it goes red.
  def spawn_unpinned(*argv)
    env = SessionEnv.neutralized(
      "CLAUDE_CODE_SESSION_ID" => SESSION,
      "CLAUDE_PROJECTS_DIR" => nil,   # THE BUG: unset ⇒ falls back to the real ~/projects
      "TASK_USAGE_SANDBOX" => "1"     # a test child always inherits this
    )
    Open3.capture3(env, RbConfig.ruby, BIN, *argv)
  end

  # ── [unit] the CLOSE path — the one no guarded-API test could see ─────────────
  #
  # THE BUG THIS FILE SHIPPED. Every violation shape above drives the guarded API, so
  # every one of them was blind to a caller that never ENTERS it — and
  # clear_activity_usage_baselines was exactly that: it took SessionMarkers' pure path
  # BUILDER and raw-File.deleted the result. Unguarded, and on the COMMON path — it
  # fires on effectively every `end`/`next` (whenever the closing activity was the last
  # one open), so a sandboxed-but-unpinned child DELETED
  # <real projects>/.agents/sessions/<sid>.activity-usage.json where every guarded
  # sibling aborts. The WRITE path was covered; the CLOSE path was not. It is now.
  #
  # Safe against the real store: the guard aborts BEFORE any IO, so this asserts the
  # refusal without ever attempting the delete it forbids.
  def test_unit_an_unpinned_activity_usage_clear_aborts_instead_of_deleting_the_real_store
    real = File.join(TaskUsageSandbox.real_state_dir, "sessions", "#{SESSION}.activity-usage.json")
    existed = File.exist?(real)

    # No CLAUDE_PROJECTS_DIR ⇒ projects_dir falls back to the operator's REAL root.
    c = AgentActivityCli.new(env: { "CLAUDE_CODE_SESSION_ID" => SESSION })

    err = capture_abort { c.send(:clear_activity_usage_baselines, SESSION) }
    assert_match(/sandbox/i, err, "the abort must say WHY")
    assert_includes err, "CLAUDE_PROJECTS_DIR", "and must name the var to pin"
    assert_equal existed, File.exist?(real), "the operator's real baseline file must be untouched"
  end

  # And the happy path the guard must not break: pinned, the clear still clears.
  def test_unit_a_pinned_activity_usage_clear_still_removes_the_baseline
    Dir.mktmpdir do |proj|
      c = cli("CLAUDE_PROJECTS_DIR" => proj)
      path = SessionMarkers.send(:marker_path, SESSION, proj, ".activity-usage.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate("77" => { "totals" => {} }))

      c.send(:clear_activity_usage_baselines, SESSION)
      refute_path_exists path, "a pinned clear must still delete the baseline — narration keeps working"
    end
  end

  def capture_abort(&block)
    original = $stderr
    $stderr = StringIO.new
    ex = assert_raises(SystemExit, "an unguarded marker mutation must ABORT, not degrade to a silent skip", &block)
    refute_predicate ex.status, :zero?, "the abort must exit non-zero"
    "#{ex.message}\n#{$stderr.string}"
  ensure
    $stderr = original
  end

  def test_integration_an_unpinned_marker_write_aborts_instead_of_reaching_the_real_store
    _out, err, status = spawn_unpinned("heartbeat", "carl")

    refute_predicate status, :success?, "a spawned child that cannot prove its marker destination must ABORT"
    assert_match(/sandbox/i, err, "the abort must say WHY")
    assert_includes err, "CLAUDE_PROJECTS_DIR", "and must name the var to pin"
    refute_path_exists File.join(TaskUsageSandbox.real_state_dir, "sessions", "#{SESSION}.acting-agent"),
                       "the operator's real marker store must be untouched"
  end

  # The happy path the guard must NOT break: pinned at a tmpdir, the same write
  # lands normally. Narration keeps working under test — a guard that fails closed
  # on the happy path is worse than the leak it closes.
  def test_integration_a_pinned_marker_write_still_lands
    Dir.mktmpdir do |proj|
      env = SessionEnv.neutralized(
        "CLAUDE_CODE_SESSION_ID" => SESSION,
        "CLAUDE_PROJECTS_DIR" => proj,
        "HOME" => proj,
        "TASK_USAGE_SANDBOX" => "1"
      )
      _out, _err, status = Open3.capture3(env, RbConfig.ruby, BIN, "heartbeat", "carl")

      assert_predicate status, :success?, "a PINNED sandboxed write must succeed"
      marker = File.join(proj, ".agents", "sessions", "#{SESSION}.acting-agent")
      assert_equal "carl\n", File.read(marker), "the sticky acting-agent still writes normally"
    end
  end
end
