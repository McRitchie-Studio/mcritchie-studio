# frozen_string_literal: true

# Tests for bin/session-insights — the SessionStart hook that feeds the curated
# Insight Bank forward into a fresh agent session.
#   ruby -Itest test/lib/session_insights_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the pure formatter — insight_line + additional_context (the
#                 SessionStart context block), loaded in process (the bin's main is
#                 guarded so `load` is side-effect free).
#   [integration] the real script, shelled out against a localhost stub that mints
#                 a token then serves /api/v1/insights, prints the SessionStart JSON.

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "time"

load File.expand_path("../../bin/session-insights", __dir__)

class SessionInsightsTest < Minitest::Test
  BIN = File.expand_path("../../bin/session-insights", __dir__)

  def tool(env = {})
    SessionInsights.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-#{rand(10_000)}" }.merge(env))
  end

  # ── [unit] insight_line ────────────────────────────────────────────────────

  def test_unit_good_insight_renders_a_do_line_with_provenance
    line = tool.insight_line("slug" => "flag the gap first", "disposition" => "good",
                             "long_form" => "check siblings", "task_slug" => "feat-x")
    assert_equal "- ✓ flag the gap first — check siblings (task: feat-x)", line
  end

  def test_unit_not_insight_renders_an_avoid_mark
    line = tool.insight_line("slug" => "did not write the test first", "disposition" => "not")
    assert_equal "- ✗ did not write the test first", line
  end

  def test_unit_insight_line_tolerates_symbol_keys
    line = tool.insight_line(slug: "symbol keyed lesson", disposition: "good")
    assert_equal "- ✓ symbol keyed lesson", line
  end

  def test_unit_insight_line_is_empty_without_a_slug
    assert_equal "", tool.insight_line("disposition" => "good")
    assert_equal "", tool.insight_line("slug" => "   ")
  end

  # ── [unit] additional_context ──────────────────────────────────────────────

  def test_unit_additional_context_wraps_rows_with_a_header
    ctx = tool.additional_context([
                                    { "slug" => "do this thing", "disposition" => "good" },
                                    { "slug" => "avoid that thing", "disposition" => "not" }
                                  ])
    assert_includes ctx, "Insights from past sessions"
    assert_includes ctx, "- ✓ do this thing"
    assert_includes ctx, "- ✗ avoid that thing"
  end

  def test_unit_additional_context_is_empty_when_nothing_renders
    assert_equal "", tool.additional_context([])
    assert_equal "", tool.additional_context([{ "disposition" => "good" }]) # no slug → no row → no block
  end

  # ── [integration] the real hook prints SessionStart injection JSON ──────────

  def test_integration_hook_emits_session_start_context
    Dir.mktmpdir do |proj|
      out, _err, status = run_bin(proj: proj, insights: [
                                    { "slug" => "flag the gap first", "disposition" => "not",
                                      "long_form" => "check siblings", "task_slug" => "feat-x" },
                                    { "slug" => "write the failing test first", "disposition" => "good" }
                                  ])

      assert_equal 0, status.exitstatus, "the hook always exits 0"
      payload = JSON.parse(out)
      hso = payload.fetch("hookSpecificOutput")
      assert_equal "SessionStart", hso["hookEventName"]
      assert_includes hso["additionalContext"], "- ✗ flag the gap first — check siblings (task: feat-x)"
      assert_includes hso["additionalContext"], "- ✓ write the failing test first"
    end
  end

  def test_integration_empty_bank_prints_nothing_and_exits_zero
    Dir.mktmpdir do |proj|
      out, _err, status = run_bin(proj: proj, insights: [])

      assert_equal 0, status.exitstatus
      assert_equal "", out.strip, "no insights → no injection, a clean session start"
    end
  end

  private

  # Shell out to the real bin against a one-shot stub that mints a token then serves
  # the given insights on GET /api/v1/insights.
  def run_bin(proj:, insights:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, insights) }

    env = {
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_PROJECTS_DIR" => proj,
      "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}",
      "CLAUDE_CODE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil
    }
    Open3.capture3(env, RbConfig.ruby, BIN)
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, insights)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      while (h = client.gets) && h != "\r\n"; end # drain headers

      status, payload =
        if path == "/api/v1/auth"
          ["200 OK", JSON.generate("token" => "stub-token", "expires_at" => (Time.now + 86_400).utc.iso8601)]
        elsif method == "GET" && path.start_with?("/api/v1/insights")
          ["200 OK", JSON.generate("data" => insights)]
        else
          ["404 Not Found", JSON.generate("error" => "unexpected #{method} #{path}")]
        end

      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end
end
