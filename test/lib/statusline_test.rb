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
end
