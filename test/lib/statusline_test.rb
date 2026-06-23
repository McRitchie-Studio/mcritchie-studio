# frozen_string_literal: true

# Standalone test for bin/statusline's session-resume segment. Runs the script
# under /bin/bash (macOS bash 3.2 — proves the portable last-4 expansion works
# there) with a temp worktree context, and asserts the …<last4> is appended when
# CLAUDE_CODE_SESSION_ID is set and omitted when it is not.
#
#   ruby -Itest test/lib/statusline_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"

class StatuslineTest < Minitest::Test
  BIN = File.expand_path("../../bin/statusline", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617" # last 4 = a617

  # Run statusline pointed at a temp worktree context (cwd via the stdin JSON, the
  # real Claude Code shape) so render() runs from a known context file. The
  # context carries ALL fields a real worktree context has (sparse ones trip
  # bash's IFS-whitespace tab collapsing). `session` nil deletes the env var.
  def render_in(session:)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate(
        "app" => "mcritchie-studio",
        "worktree_slug" => "session-resume-v1",
        "task_record_slug" => "session-resume-on-tasks",
        "task_url" => "https://mcritchie.studio/tasks/session-resume-on-tasks",
        "stage" => "building"
      ))
      env = { "CLAUDE_CODE_SESSION_ID" => session }
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      out, = Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      out
    end
  end

  def test_appends_session_last4_when_session_is_set
    out = render_in(session: SESSION)
    assert_includes out, "…a617", "status line should append the session last-4"
    assert_includes out, "[building]", "the stage segment should still render"
  end

  def test_omits_session_last4_when_no_session
    out = render_in(session: nil)
    refute_includes out, "…a617", "no session → no last-4 segment"
    assert_includes out, "[building]", "the no-session path must still render the stage"
  end

  # --- Heartbeat wiring (V2): the status line renews the active build claim ----

  # Run statusline with a stub `task` binary (records its args) wired in via
  # TASK_BIN, in foreground heartbeat mode so the call is observable. Returns the
  # recorded invocations (one per line, e.g. "heartbeat <slug>").
  def heartbeat_calls(stage:, runs: 1, session: SESSION, slug: "session-claim-lease-gate")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate(
        "app" => "mcritchie-studio",
        "worktree_slug" => "session-claim-lease-gate",
        "task_record_slug" => slug,
        "task_url" => "https://mcritchie.studio/tasks/#{slug}",
        "stage" => stage
      ))
      calls = File.join(dir, "calls.log")
      stub = File.join(dir, "task")
      File.write(stub, "#!/bin/bash\necho \"$@\" >> #{calls.inspect}\n")
      File.chmod(0o755, stub)

      env = {
        "CLAUDE_CODE_SESSION_ID" => session,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => File.join(dir, "projects")
      }
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      runs.times { Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL) }

      File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
    end
  end

  def test_statusline_fires_the_heartbeat_for_the_active_building_task
    calls = heartbeat_calls(stage: "building")
    assert_equal ["heartbeat session-claim-lease-gate"], calls,
                 "a building task's status line should renew its claim via `task heartbeat <slug>`"
  end

  def test_statusline_throttles_repeated_heartbeats
    calls = heartbeat_calls(stage: "building", runs: 3)
    assert_equal 1, calls.size, "the throttle suppresses repeat heartbeats within the window"
  end

  def test_statusline_does_not_heartbeat_a_non_building_task
    assert_empty heartbeat_calls(stage: "submitted"),
                 "only the live BUILD claim is renewed — other stages don't heartbeat"
  end

  def test_statusline_does_not_heartbeat_without_a_session
    assert_empty heartbeat_calls(stage: "building", session: nil),
                 "no session → no claim to renew"
  end
end
