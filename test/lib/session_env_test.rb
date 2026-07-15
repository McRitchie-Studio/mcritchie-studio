# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../support/session_env"

# The PRODUCTION counterpart, loaded for real so the drift guard below compares
# against the LIVE list instead of a copy of it. Release::GateEnv is PURE and
# Rails-free by construction (see its header) — bin/release.rb requires it exactly
# this way, and so must the BARE run of this file (`ruby test/lib/session_env_test.rb`),
# which has no autoloader.
#
# Gate on WHETHER ZEITWERK WILL OWN app/models — not on the constant being defined
# yet. The `unless defined?(Release::GateEnv)` guard that used to stand here did NOT
# save us. Under `bin/rails test` the runner requires the test files BEFORE any of
# them boots the app (this one deliberately never requires test_helper), so when this
# file loaded first the constant was undefined, the require_relative fired, and it
# defined ::Release as a PLAIN MODULE. Zeitwerk could then never take the name back —
# Ruby's `autoload` is a NO-OP on an already-defined constant — so the real Release AR
# model stayed shadowed and every later test in the process died on Task#release with
# "The Release model class ... is not an ActiveRecord::Base subclass". That is the
# order-dependent false-red that the release gate (which collects all of test/lib)
# tripped over, while GitHub CI stayed green on the same SHA.
#
# `defined?(Rails)` alone is NOT enough either: railties is loaded, so the constant
# exists, but the app is not initialized and nothing is autoloadable yet. So BOOT the
# app — exactly what test_helper does — and then let Zeitwerk resolve the constant.
# Bare (`ruby test/lib/session_env_test.rb`, and the same load path bin/release.rb
# uses) there is no Rails at all, and the require_relative is correct and load-bearing.
if defined?(Rails)
  require_relative "../../config/environment"
  Release::GateEnv.name # Zeitwerk resolves it — never require_relative an autoloadable path
else
  require_relative "../../app/models/release/gate_env"
end

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

  # DERIVED from SESSION_KEYS, not a literal copy of it. A hard-coded hash here
  # would go red on the CORRECT lockstep edit (a key added to both lists) — and a
  # guard that punishes the right fix just teaches the next agent to delete it.
  def test_neutralized_unsets_every_session_key
    assert_equal SessionEnv::SESSION_KEYS.to_h { |key| [key, nil] }, SessionEnv.neutralized
  end

  # THE DRIFT GUARD. Assert against the LIVE production constant, never a literal
  # copy of it: a literal only pins the SessionEnv side, so a key added to
  # Release::GateEnv::SESSION_KEYS ALONE would keep this green while the new var
  # leaked into every spawner test — restoring the exact bug class the neutralizer
  # exists to kill. Comparing the two live lists fails on drift from EITHER side.
  def test_keys_match_the_production_gate_env_list
    assert_equal Release::GateEnv::SESSION_KEYS, SessionEnv::SESSION_KEYS,
                 "SessionEnv and Release::GateEnv session keys have DRIFTED — " \
                 "they must stay in lockstep; add the key to both."
  end

  # THE POISONING GUARD. Loading this file must never shadow the ::Release AR model
  # with a plain module — the bug that made the release gate a false-red: a
  # require_relative of the autoloadable app/models/release/gate_env.rb defined
  # ::Release itself outside Zeitwerk, and every later test in the process died on
  # Task#release. Asserted as the POSITIVE property (Release is the real model), so
  # it holds against any spelling of the mistake, not just the one we made. Skipped
  # bare, where there is no Rails and a plain ::Release module is the correct answer.
  def test_loading_this_file_does_not_shadow_the_release_model
    skip "no Rails in the bare run — a plain ::Release module is correct here" unless defined?(Rails)

    # Both halves of the contract, each with its own legible red. The boot assertion
    # is not ceremony: it is the state the OLD code silently skipped, and without it
    # a reintroduced require_relative fails here as a baffling "uninitialized constant
    # ActiveRecord" instead of naming the actual mistake.
    assert Rails.application&.initialized?,
           "Rails is loaded but the app was never booted — nothing under app/ is autoloadable"
    assert_operator Release, :<, ActiveRecord::Base,
                    "::Release was defined OUTSIDE Zeitwerk — an autoloadable path was require_relative'd"
  end

  # The same contract asserted as BEHAVIOR, end-to-end through a real spawn: every
  # key production scrubs must actually be absent from the child. List equality
  # above could be satisfied by two agreeing-but-broken lists; this proves the
  # scrub covers the production contract in the only place that matters — the
  # child's ENV.
  def test_every_production_session_key_is_absent_from_the_child
    keys = Release::GateEnv::SESSION_KEYS
    live = keys.to_h { |key| [key, "live-#{key.downcase}"] }
    probe = "print #{keys.inspect}.map { |k| ENV[k].inspect }.join(',')"

    with_env(live) do
      out, status = Open3.capture2(SessionEnv.neutralized, RbConfig.ruby, "-e", probe)
      assert status.success?, "probe failed"
      assert_equal Array.new(keys.size, "nil").join(","), out,
                   "a production session key leaked into the spawned child"
    end
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
    # Iterate SESSION_KEYS so a newly added key is COVERED here automatically; a
    # literal list would silently leave it untested.
    SessionEnv::SESSION_KEYS.each do |key|
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
