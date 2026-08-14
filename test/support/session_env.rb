# frozen_string_literal: true

# SessionEnv — the ONE neutralizer for the ambient agent-session vars a test's
# SUBPROCESS would otherwise inherit.
#
# WHY (rediscovered at least three times; it poisoned a release gate):
# an interactive Claude session exports CLAUDE_CODE_SESSION_ID (Codex:
# CODEX_THREAD_ID); CI and a plain shell export NEITHER. Any test that spawns a
# bin/ command (bin/task, bin/fast-check, bin/dor-check, bin/pr-review,
# bin/agent-activity, …) via Open3 / IO.popen / Process.spawn hands the var
# straight down, so SessionIdentity (bin/lib/session_identity.rb) resolves the
# OPERATOR'S LIVE SESSION where CI resolves none. Actor/persona defaulting then
# takes the wrong branch, best-effort narration shells out to the real board
# mid-test, and the assertion false-fails — but ONLY for the agent running the
# suite by hand. CI stays green, which is exactly what hides the coupling and
# lets it be rediscovered instead of fixed.
#
# So: a test that spawns a subprocess MUST build its child env through here.
#
#   env = SessionEnv.neutralized("FOO" => "bar")          # FOO set, session UNSET
#   out = IO.popen(env, cmd, &:read)
#   Open3.capture2(SessionEnv.neutralized, *cmd)          # bare overlay
#   SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => s) # opt IN to a fake session
#
# nil means UNSET, and that is the whole point. A nil value REMOVES the key in
# the child (Process.spawn semantics). Setting "" instead would still EXPORT the
# var: SessionIdentity happens to treat a blank id as absent, but any reader
# keying on PRESENCE (ENV.key?, a shell's `${VAR+set}`) sees a session that
# isn't there. Neutralized means gone, not empty.
#
# Standalone by construction. The test/lib/*.rb and test/commands/*.rb files are
# bare `minitest/autorun` — they do NOT require test_helper — so this file must
# load with no Rails and no test_helper. Both worlds reach it the same way:
#
#   require_relative "../support/session_env"   # standalone minitest files
#   (test_helper requires it too, for the Rails-side tests)
#
# SIBLING GUARANTEE: requiring this file also arms the task-usage sandbox
# (test/support/task_usage_sandbox.rb), which turns TASK_USAGE_SANDBOX on for the
# test process so every child inherits it and is REFUSED — loudly — if it tries to
# write the operator's real .agents state (its usage/cost baselines or its session
# markers). Same reasoning as the session neutralizer above, one store further in:
# a test child that reaches the operator's real state is a bug whether it READS an
# ambient session id or WRITES a fixture row into their live cost store. It rides
# here because this is the ONE file every subprocess-spawning test already loads.
#
# PRODUCTION COUNTERPART: Release::GateEnv (app/models/release/gate_env.rb) does
# the same scrub for the release gate's own spawn env — same SESSION_KEYS, same
# nil-means-unset rule. That covers `bin/release`'s gate runs; it does nothing
# for an agent running `bin/rails test` by hand in a worktree, which is what this
# helper covers.
#
# The two are deliberately NOT shared code: THIS file must load in a bare
# minitest/autorun file with no Rails, so it cannot be the one to reach across.
# The dependency runs ONE WAY — a TEST may require Release::GateEnv (it is PURE and
# Rails-free by construction, exactly as bin/release.rb requires it), but production
# code never reaches into test/. Hence two lists, which MUST agree.
#
# They are kept in lockstep MECHANICALLY, not on trust: SessionEnvTest
# (test/lib/session_env_test.rb) requires Release::GateEnv and asserts the two lists
# are EQUAL, so growing either one alone fails the suite.
# SECOND SIBLING, same reasoning one step further out: requiring this file also
# arms the OUTBOUND FLOOR (test/support/outbound_seams.rb), which pins the two
# board URLs and the GitHub token broker for this process so every child inherits
# them. The session scrub stops a child resolving the operator's SESSION; the floor
# stops it reaching the operator's WORLD — bin/task defaults TASK_API_BASE to
# https://mcritchie.studio, so an unpinned child WRITES TO THE PRODUCTION BOARD,
# and a leaked `gh` refusal mints a real credential through 1Password. Both were
# measured, both were silent successes rather than failures, and both lived in
# files whose authors believed them sealed. It rides here for the same reason the
# sandbox does: this is the file they all already load.
require_relative "task_usage_sandbox"
require_relative "outbound_seams"

module SessionEnv
  # The agent-session identity vars, exactly as Release::GateEnv::SESSION_KEYS names
  # them. Add a key HERE and you must add it THERE — SessionEnvTest compares the two
  # live lists and goes red otherwise. Everything below DERIVES from this list, so
  # adding a key needs no other edit in this file.
  SESSION_KEYS = %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].freeze

  # The bare overlay: every session var UNSET. Frozen — build variants with
  # `neutralized(...)`, never by mutating this.
  NEUTRALIZED = SESSION_KEYS.each_with_object({}) { |key, env| env[key] = nil }.freeze

  module_function

  # The child env hash for a spawned subprocess: every session var UNSET, with
  # `overrides` merged ON TOP.
  #
  # A test may deliberately opt a session back IN by passing one — that's a
  # merge, not a clobber, so the fake-session tests keep working. A BLANK session
  # override ("" / nil / "  ") normalizes to UNSET, because a blank session id
  # means "no session" and an exported empty string is a lie about that. Non-
  # session keys pass through untouched, blank or not.
  def neutralized(overrides = {})
    env = NEUTRALIZED.dup
    overrides.each do |key, value|
      key = key.to_s
      env[key] = SESSION_KEYS.include?(key) ? presence(value) : value
    end
    env
  end

  # The value unless it is blank; nil (⇒ UNSET) when it is.
  def presence(value)
    value.to_s.strip.empty? ? nil : value
  end
end
