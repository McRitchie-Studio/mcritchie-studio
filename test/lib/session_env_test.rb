# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../support/session_env"

# The neutralizer's own contract. Standalone (bare minitest/autorun) BY DESIGN —
# it is the same load path the test/lib/*.rb spawner tests use, so this file
# failing to load is itself the regression signal.
class SessionEnvTest < Minitest::Test
  # The child probe: print both session vars as Ruby literals. `nil` in the
  # output means the key is genuinely ABSENT from the child's ENV.
  PROBE = 'print [ENV["CLAUDE_CODE_SESSION_ID"].inspect, ENV["CODEX_THREAD_ID"].inspect].join(",")'

  def child_sees(env)
    out, status = Open3.capture2(env, RbConfig.ruby, "-e", PROBE)
    assert status.success?, "probe failed"
    out
  end

  def test_neutralized_unsets_both_session_keys
    assert_equal({ "CLAUDE_CODE_SESSION_ID" => nil, "CODEX_THREAD_ID" => nil }, SessionEnv.neutralized)
  end

  def test_keys_match_the_production_gate_env_list
    # Release::GateEnv::SESSION_KEYS is the production counterpart. It is not
    # requirable here (Rails-side), so pin the list by VALUE and let this fail
    # loudly if either side grows a key alone.
    assert_equal %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID], SessionEnv::SESSION_KEYS
  end

  def test_overrides_merge_on_top_without_dropping_the_scrub
    env = SessionEnv.neutralized("FOO" => "bar")

    assert_equal "bar", env["FOO"]
    assert_nil env["CLAUDE_CODE_SESSION_ID"]
    assert_nil env["CODEX_THREAD_ID"]
  end

  def test_a_test_may_opt_a_fake_session_back_in
    env = SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => "fake-sid")

    assert_equal "fake-sid", env["CLAUDE_CODE_SESSION_ID"]
    assert_nil env["CODEX_THREAD_ID"], "the OTHER session key stays scrubbed"
  end

  def test_a_blank_session_override_normalizes_to_unset
    # "" means "no session" — but an exported "" is a lie to any presence check.
    %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].each do |key|
      ["", "   ", nil].each do |blank|
        assert_nil SessionEnv.neutralized(key => blank)[key], "#{key}=#{blank.inspect} must UNSET"
      end
    end
  end

  def test_a_blank_non_session_value_passes_through
    assert_equal "", SessionEnv.neutralized("FOO" => "")["FOO"]
  end

  def test_symbol_keys_are_accepted
    assert_nil SessionEnv.neutralized(CLAUDE_CODE_SESSION_ID: "")["CLAUDE_CODE_SESSION_ID"]
    assert_equal "bar", SessionEnv.neutralized(FOO: "bar")["FOO"]
  end

  def test_neutralized_constant_is_not_mutated_by_a_caller
    SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => "leak")

    assert_nil SessionEnv::NEUTRALIZED["CLAUDE_CODE_SESSION_ID"]
    assert_predicate SessionEnv::NEUTRALIZED, :frozen?
  end

  # THE POINT OF THE WHOLE FILE. A live agent session exports the var; the child
  # must not see it. Run under a session we FAKE into this process's ENV so the
  # test proves the scrub on CI (which exports nothing) as well as from a live
  # agent session (which exports the real thing).
  def test_the_child_process_does_not_inherit_a_live_session
    with_env("CLAUDE_CODE_SESSION_ID" => "live-operator-session", "CODEX_THREAD_ID" => "live-codex-thread") do
      assert_equal "nil,nil", child_sees(SessionEnv.neutralized),
                   "the spawned child inherited the ambient agent session"
    end
  end

  # The unscrubbed control: without the helper the child DOES inherit it. This is
  # the bug, asserted — if this ever stops holding, the leak is gone at the source
  # and this whole helper can be reconsidered.
  def test_control_an_unscrubbed_child_does_inherit_the_live_session
    with_env("CLAUDE_CODE_SESSION_ID" => "live-operator-session", "CODEX_THREAD_ID" => nil) do
      assert_equal %("live-operator-session",nil), child_sees({})
    end
  end

  # An EMPTY STRING is still exported — the exact reason the overlay uses nil.
  def test_control_an_empty_string_is_still_exported_to_the_child
    with_env("CLAUDE_CODE_SESSION_ID" => "live-operator-session", "CODEX_THREAD_ID" => nil) do
      assert_equal %("",nil), child_sees("CLAUDE_CODE_SESSION_ID" => "")
    end
  end

  def with_env(overrides)
    saved = overrides.keys.to_h { |key| [key, ENV[key]] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
