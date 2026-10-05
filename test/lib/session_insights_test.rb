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
require_relative "../support/session_env"

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

  # ── [unit] session_context joins the dream and insight blocks ───────────────

  def test_unit_session_context_puts_dreams_ahead_of_insights
    assert_equal "DREAMS\n\nINSIGHTS", tool.session_context(dreams: "DREAMS\n", insights: "INSIGHTS")
  end

  def test_unit_session_context_stands_on_either_block_alone
    assert_equal "DREAMS", tool.session_context(dreams: "DREAMS", insights: "")
    assert_equal "INSIGHTS", tool.session_context(dreams: "", insights: "INSIGHTS")
    assert_equal "", tool.session_context(dreams: " ", insights: nil)
  end

  # ── [unit] the hook cap: one string, 10,000 characters ─────────────────────
  #
  # Claude Code caps a hook's additionalContext at 10,000 characters. Over it the
  # model is handed a file path and a 2,000-character preview, which loses most
  # dreams and EVERY insight without a word. These pin the size, so the dream
  # that tips the bank over fails here instead of truncating in production.

  HOOK_CAP = 10_000
  # Room held for the insight feed: 12 rows, each a slug, a long form and a task.
  # The live feed measured 1,834 characters on 2026-10-05.
  INSIGHT_RESERVE = 2_500

  def test_unit_the_budget_sits_under_the_hook_cap
    assert_operator SessionInsights::CONTEXT_BUDGET, :<, HOOK_CAP
  end

  def test_unit_dream_budget_leaves_the_insights_whole
    insights = "x" * 1_800

    assert_equal SessionInsights::CONTEXT_BUDGET, tool.dream_budget("")
    assert_equal SessionInsights::CONTEXT_BUDGET - 1_800 - 2, tool.dream_budget(insights)
  end

  def test_unit_the_real_bank_and_a_full_feed_fit_under_the_cap_with_every_dream
    approved = DreamBank.approved
    insights = "## Insights\n" + ("- x" * 1).ljust(INSIGHT_RESERVE - 12, "x")
    real = SessionInsights.new(env: {}, dreams_dir: DreamBank::DEFAULT_DIR)

    dreams = real.dream_context(budget: real.dream_budget(insights))
    context = real.session_context(dreams: dreams, insights: insights)

    assert_operator context.size, :<=, HOOK_CAP
    assert_includes context, insights, "the insights are never trimmed for a dream"
    assert_equal approved.size, dreams.scan(/^\*\*Q:/).size,
                 "the approved bank no longer fits beside a full insight feed: " \
                 "#{approved.size} approved, #{dreams.scan(/^\*\*Q:/).size} loaded. " \
                 "Shorten a dream or retire one (docs/agents/modules/dream.md, The ceiling)."
    refute_includes dreams, "did not fit this block"
  end

  def test_unit_an_oversized_feed_squeezes_the_dreams_and_never_the_insights
    insights = "## Insights\n" + ("y" * 9_000)
    real = SessionInsights.new(env: {}, dreams_dir: DreamBank::DEFAULT_DIR)

    context = real.session_context(dreams: real.dream_context(budget: real.dream_budget(insights)), insights: insights)

    assert_operator context.size, :<=, HOOK_CAP
    assert_includes context, insights
  end

  # ── [integration] dreams load from disk, with or without the board ─────────

  def test_integration_approved_dreams_load_ahead_of_the_insights
    with_dream_dir do |dreams|
      Dir.mktmpdir do |proj|
        out, _err, status = run_bin(proj: proj, dreams_dir: dreams,
                                    insights: [ { "slug" => "write the failing test first", "disposition" => "good" } ])

        assert_equal 0, status.exitstatus
        context = JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
        assert_includes context, "**Q: Do I merge on one read?** (`wait-for-it`)"
        refute_includes context, "candidate", "a proposed dream reaches no session"
        assert_operator context.index("## Dreams"), :<, context.index("## Insights")
      end
    end
  end

  # The board is DOWN here: nothing listens on the port, so the insight fetch fails.
  # The dreams are local files and must still arrive.
  def test_integration_dreams_load_with_the_board_unreachable
    with_dream_dir do |dreams|
      Dir.mktmpdir do |proj|
        env = SessionEnv.neutralized("AGENT_API_SECRET" => "test-secret", "CLAUDE_PROJECTS_DIR" => proj,
                                     "DREAM_BANK_DIR" => dreams, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{closed_port}")
        out, _err, status = Open3.capture3(env, RbConfig.ruby, BIN)

        assert_equal 0, status.exitstatus
        context = JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
        assert_includes context, "A: No. Wait for the report."
        refute_includes context, "## Insights"
      end
    end
  end

  private

  def with_dream_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "wait-for-it.md"),
                 "---\nquestion: \"Do I merge on one read?\"\nanswer: \"No. Wait for the report.\"\n" \
                 "why: \"A late blocker costs a whole task.\"\nstatus: approved\n---\n\n# Wait\n")
      File.write(File.join(dir, "not-yet.md"),
                 "---\nquestion: \"A candidate question?\"\nanswer: \"A candidate answer.\"\nstatus: proposed\n---\n")
      yield dir
    end
  end

  # A port with nothing listening: bind one, read its number, release it.
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Shell out to the real bin against a one-shot stub that mints a token then serves
  # the given insights on GET /api/v1/insights.
  #
  # dreams_dir defaults to the empty tmp project dir, NOT the repo's real bank: the
  # insight tests must not start failing the day a dream is approved.
  def run_bin(proj:, insights:, dreams_dir: proj)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { serve(server, insights) }

    # SessionEnv.neutralized: the child must name NO agent session (test/support/session_env.rb).
    env = SessionEnv.neutralized(
      "AGENT_API_SECRET" => "test-secret",
      "CLAUDE_PROJECTS_DIR" => proj,
      "DREAM_BANK_DIR" => dreams_dir,
      "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:#{port}"
    )
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
