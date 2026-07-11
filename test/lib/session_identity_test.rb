# frozen_string_literal: true

# Tests for bin/lib/session_identity.rb — the Claude-then-Codex session-id
# chain shared by bin/task, bin/reviewer-select, bin/release.rb,
# bin/full-suite-check, bin/ci-scope-capture and bin/atomic-event. The chain is
# shared; the missing-session fallback stays per-caller, so identity returns
# [nil, nil] and callers map it.
#   ruby -Itest test/lib/session_identity_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

require File.expand_path("../../bin/lib/session_identity", __dir__)

class SessionIdentityTest < Minitest::Test
  def test_unit_claude_wins_over_codex
    env = { "CLAUDE_CODE_SESSION_ID" => "c-1", "CODEX_THREAD_ID" => "x-1" }
    assert_equal ["c-1", "claude"], SessionIdentity.identity(env)
  end

  def test_unit_codex_is_the_fallback
    assert_equal ["x-1", "codex"], SessionIdentity.identity("CODEX_THREAD_ID" => "x-1")
  end

  def test_unit_blank_values_are_skipped
    env = { "CLAUDE_CODE_SESSION_ID" => "   ", "CODEX_THREAD_ID" => "x-2" }
    assert_equal ["x-2", "codex"], SessionIdentity.identity(env)
  end

  def test_unit_ids_are_stripped
    assert_equal ["c-9", "claude"], SessionIdentity.identity("CLAUDE_CODE_SESSION_ID" => " c-9 ")
  end

  def test_unit_no_session_is_nil_nil
    assert_equal [nil, nil], SessionIdentity.identity({}),
                 "callers map [nil, nil] to their own fallback posture"
  end

  def test_unit_id_returns_the_bare_id_or_empty_string
    assert_equal "c-1", SessionIdentity.id("CLAUDE_CODE_SESSION_ID" => "c-1")
    assert_equal "", SessionIdentity.id({}), "the telemetry session gate keys off blank"
  end
end
