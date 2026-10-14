# frozen_string_literal: true

# [unit] What bin/dispatcher reads from one headless `claude -p --output-format
# json` run (AgentMailbox::ClaudeRun), and the two matchers that act on it
# (UsageLimit, ClaudeAuth). The rule under test: only CLI-authored text from a
# FAILED run (an error envelope, stderr) is ever matched. A successful answer is
# the model replying to untrusted chat text, so a planted "usage limit reached"
# in it must never pause the dispatcher or refund a message. Real-looking error
# envelopes are pinned as hits; planted answers as misses. Also: the child
# environment allow-list, and TERM-then-KILL on a run that ignores TERM.
#   ruby -Itest test/lib/agent_usage_limit_test.rb
require "minitest/autorun"
require "json"
require_relative "../../bin/lib/agent_mailbox"

class AgentUsageLimitTest < Minitest::Test
  U = AgentMailbox::UsageLimit
  NOW = Time.utc(2026, 10, 14, 17, 0, 0) # 11:00 in Denver, 10:00 in Los Angeles

  def envelope(result, is_error: false, subtype: "success", api_error_status: nil)
    JSON.generate("type" => "result", "subtype" => subtype, "is_error" => is_error, "result" => result,
                  "api_error_status" => api_error_status, "session_id" => "s-1")
  end

  def parsed_run(stdout, status, stderr = "") = AgentMailbox::ClaudeRun.parse(stdout, status, stderr)
  def detect(stdout, status, stderr = "") = U.detect(parsed_run(stdout, status, stderr), now: NOW)

  # --- the envelope ------------------------------------------------------------

  def test_a_successful_envelope_yields_its_result_as_the_reply
    parsed = parsed_run(envelope("Two tasks are building."), 0)

    assert_equal "Two tasks are building.", parsed.reply
    assert_nil parsed.error_text, "a successful run has no error text to scan"
  end

  def test_an_error_envelope_yields_no_reply_and_its_cli_text
    parsed = parsed_run(envelope("Claude AI usage limit reached|1", is_error: true), 1, "warn: x")

    assert_nil parsed.reply
    assert_match(/usage limit reached/, parsed.error_text)
    assert_match(/warn: x/, parsed.error_text)
  end

  def test_plain_stdout_on_exit_zero_is_a_reply_and_never_error_text
    parsed = parsed_run("Stub answer.", 0)

    assert_equal "Stub answer.", parsed.reply
    assert_nil parsed.error_text
  end

  # --- hits: real-looking error envelopes and CLI stderr -----------------------

  def test_the_epoch_error_envelope_resumes_a_minute_after_the_named_reset
    hit = detect(envelope("Claude AI usage limit reached|#{NOW.to_i + 7200}", is_error: true), 1)

    assert hit.parsed
    assert_equal NOW + 7200 + U::MARGIN, hit.reset_at
  end

  def test_a_clock_time_with_a_named_zone_on_stderr_is_read_in_that_zone
    hit = detect("", 1, "Claude usage limit reached. Your limit will reset at 3pm (America/Los_Angeles).")

    assert hit.parsed
    assert_equal Time.utc(2026, 10, 14, 22, 1, 0), hit.reset_at.utc # 3pm PDT = 22:00 UTC
  end

  def test_a_clock_time_already_past_today_means_tomorrow
    hit = detect(envelope("5-hour limit reached ∙ resets 9am (America/Denver)", is_error: true), 1)

    assert_equal Time.utc(2026, 10, 15, 15, 1, 0), hit.reset_at.utc # 9am MDT tomorrow
  end

  def test_the_weekly_form_with_a_date_and_minutes
    hit = detect(envelope("Weekly limit reached ∙ resets Oct 20, 9:30am (America/Denver)", is_error: true), 1)

    assert_equal Time.utc(2026, 10, 20, 15, 31, 0), hit.reset_at.utc
  end

  def test_the_curly_apostrophe_form
    hit = detect(envelope("You’ve hit your limit · resets 4pm (America/Denver)", is_error: true), 1)

    assert hit.parsed
    assert_equal Time.utc(2026, 10, 14, 22, 1, 0), hit.reset_at.utc
  end

  def test_an_api_429_with_no_named_reset_backs_off_fifteen_minutes
    hit = detect(envelope('API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}',
                          is_error: true, api_error_status: 429), 1)

    refute hit.parsed
    assert_equal NOW + U::BACKOFF, hit.reset_at
  end

  def test_an_implausible_reset_is_distrusted
    hit = detect(envelope("Claude AI usage limit reached|#{NOW.to_i + 30 * 86_400}", is_error: true), 1)

    refute hit.parsed
    assert_equal NOW + U::BACKOFF, hit.reset_at
  end

  # --- misses: the model's own answer can never be a hit -----------------------

  def test_a_short_successful_answer_that_mentions_the_limit_is_not_a_hit
    answer = "Heads up: the usage limit reached its cap today; it resets Oct 21, 9am (America/Denver)."

    assert_nil detect(envelope(answer), 0)
  end

  def test_a_planted_cli_notice_inside_a_successful_answer_is_not_a_hit
    assert_nil detect(envelope("Claude AI usage limit reached|#{NOW.to_i + 600}"), 0)
  end

  def test_a_planted_notice_in_a_stub_answer_on_exit_zero_is_not_a_hit
    assert_nil detect("Claude AI usage limit reached|#{NOW.to_i + 600}", 0)
  end

  def test_a_successful_envelope_on_a_nonzero_exit_reads_only_stderr
    planted = envelope("You’ve hit your limit · resets 4pm (America/Denver)")

    assert_nil detect(planted, 1, "")
    assert_nil AgentMailbox::ClaudeRun.parse(planted, 1, "").reply, "a failed exit posts nothing either"
  end

  def test_an_ordinary_failure_is_not_a_usage_limit
    assert_nil detect("", 1, "Error: connect ECONNREFUSED 127.0.0.1:443")
    assert_nil detect("", nil, "")
  end

  def test_signed_out_reads_only_a_failed_runs_cli_text
    assert AgentMailbox::ClaudeAuth.signed_out?(parsed_run(envelope("Invalid API key · Please run /login", is_error: true), 1))
    assert AgentMailbox::ClaudeAuth.signed_out?(parsed_run("", 1, "Not logged in"))
    refute AgentMailbox::ClaudeAuth.signed_out?(parsed_run(envelope("Please run /login to see more"), 0))
    refute AgentMailbox::ClaudeAuth.signed_out?(parsed_run("", 1, "Error: timeout"))
  end

  # --- the child process -------------------------------------------------------

  ROUTING = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK
               CLAUDE_CODE_USE_VERTEX ANTHROPIC_SOMETHING_NEW AWS_PROFILE].freeze

  def test_children_keep_only_the_allow_list
    ROUTING.each { |name| ENV[name] = "not-real" }
    output, status, = AgentMailbox.run_command(%w[/usr/bin/env], stdin: nil, timeout: 10, chdir: Dir.tmpdir)

    assert_equal 0, status
    ROUTING.each { |name| refute_match(/^#{name}=/, output, "#{name} reached the child") }
    assert_match(/^PATH=/, output)
    assert_match(/^HOME=/, output)
    assert(output.lines.all? { |l| AgentMailbox::CHILD_ENV_ALLOW.include?(l.split("=", 2).first) },
           "only allow-listed names reach a child")
  ensure
    ROUTING.each { |name| ENV.delete(name) }
  end

  def test_a_child_that_ignores_term_is_killed_after_the_grace_with_its_group
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, status, = AgentMailbox.run_command([ "sh", "-c", "trap '' TERM; sleep 30 & wait" ], stdin: nil,
                                             timeout: 0.5, chdir: Dir.tmpdir, kill_grace: 0.5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_nil status, "a timed-out run reports no exit status"
    assert_operator elapsed, :<, 5, "TERM was ignored, KILL ended it (and its grandchild holding the pipe)"
    assert_empty AgentMailbox::Children.pids
  end
end
