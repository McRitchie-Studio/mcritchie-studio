# frozen_string_literal: true

# [unit] AgentMailbox::UsageLimit and ClaudeAuth — the deterministic readers of
# a headless `claude -p` run that bin/dispatcher acts on: a usage-limit notice
# hands the message back without spending its attempt and pauses until the
# reset; a signed-out notice pauses longer. Real-looking notices are pinned here,
# with the controls that must NOT match.
#   ruby -Itest test/lib/agent_usage_limit_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/agent_mailbox"

class AgentUsageLimitTest < Minitest::Test
  U = AgentMailbox::UsageLimit
  NOW = Time.utc(2026, 10, 14, 17, 0, 0) # 11:00 in Denver, 10:00 in Los Angeles

  def detect(text, status = 1) = U.detect(text, status, now: NOW)

  def test_the_epoch_form_resumes_a_minute_after_the_named_reset
    hit = detect("Claude AI usage limit reached|#{NOW.to_i + 7200}")

    assert hit.parsed
    assert_equal NOW + 7200 + U::MARGIN, hit.reset_at
  end

  def test_a_clock_time_with_a_named_zone_is_read_in_that_zone
    hit = detect("Claude usage limit reached. Your limit will reset at 3pm (America/Los_Angeles).")

    assert hit.parsed
    assert_equal Time.utc(2026, 10, 14, 22, 1, 0), hit.reset_at.utc # 3pm PDT = 22:00 UTC
  end

  def test_a_clock_time_already_past_today_means_tomorrow
    hit = detect("5-hour limit reached ∙ resets 9am (America/Denver)")

    assert_equal Time.utc(2026, 10, 15, 15, 1, 0), hit.reset_at.utc # 9am MDT tomorrow
  end

  def test_the_weekly_form_with_a_date_and_minutes
    hit = detect("Weekly limit reached ∙ resets Oct 20, 9:30am (America/Denver)")

    assert_equal Time.utc(2026, 10, 20, 15, 31, 0), hit.reset_at.utc
  end

  def test_the_curly_apostrophe_form
    hit = detect("You’ve hit your limit · resets 4pm (America/Denver)")

    assert hit.parsed
    assert_equal Time.utc(2026, 10, 14, 22, 1, 0), hit.reset_at.utc
  end

  def test_a_notice_with_no_reset_backs_off_fifteen_minutes
    hit = detect('API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}')

    refute hit.parsed
    assert_equal NOW + U::BACKOFF, hit.reset_at
  end

  def test_an_implausible_reset_is_distrusted
    hit = detect("Claude AI usage limit reached|#{NOW.to_i + 30 * 86_400}")

    refute hit.parsed
    assert_equal NOW + U::BACKOFF, hit.reset_at
  end

  def test_a_short_notice_counts_even_on_exit_zero
    assert detect("Claude AI usage limit reached|#{NOW.to_i + 60}", 0)
  end

  # --- the controls: these must NOT read as a usage limit ----------------------

  def test_an_ordinary_failure_is_not_a_usage_limit
    assert_nil detect("Error: connect ECONNREFUSED 127.0.0.1:443")
    assert_nil detect("", nil)
  end

  def test_a_long_successful_answer_that_mentions_the_limit_is_not_one
    answer = "The usage limit reached a new high this week, so here is the board. " + ("Task x is building. " * 30)

    assert_nil detect(answer, 0)
  end

  def test_signed_out_reads_only_on_a_failed_run
    assert AgentMailbox::ClaudeAuth.signed_out?("Invalid API key · Please run /login", 1)
    assert AgentMailbox::ClaudeAuth.signed_out?("Not logged in", 1)
    refute AgentMailbox::ClaudeAuth.signed_out?("Please run /login to see more", 0)
    refute AgentMailbox::ClaudeAuth.signed_out?("Error: timeout", 1)
  end

  # --- the child environment ---------------------------------------------------

  def test_children_never_see_an_api_key
    ENV["ANTHROPIC_API_KEY"] = "sk-test-not-real"
    output, status, = AgentMailbox.run_command(%w[/usr/bin/env], stdin: nil, timeout: 10, chdir: Dir.tmpdir)

    assert_equal 0, status
    refute_match(/ANTHROPIC_API_KEY/, output, "the subscription bills, never an API key")
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end
end
