# frozen_string_literal: true

# SessionIdentity — the ONE Claude-then-Codex session-id chain the bin/ stack
# repeats: Claude Code exposes CLAUDE_CODE_SESSION_ID, Codex exposes
# CODEX_THREAD_ID, and a plain shell / CI run exposes neither.
#
# The chain is shared; the MISSING-session fallback is not — callers keep their
# own ([nil, nil] in bin/task, ["", "claude"] in bin/reviewer-select,
# [nil, "claude"] in bin/release.rb), so `identity` returns [nil, nil] and each
# caller maps that to its posture. bin/atomic-capture-hook is NOT a consumer:
# its event-payload resolution checks CODEX first by design.
module SessionIdentity
  module_function

  # [session_id, provider] — ["<id>", "claude"] / ["<id>", "codex"], or
  # [nil, nil] when the environment names no session.
  def identity(env = ENV)
    claude = env["CLAUDE_CODE_SESSION_ID"].to_s.strip
    return [claude, "claude"] unless claude.empty?

    codex = env["CODEX_THREAD_ID"].to_s.strip
    return [codex, "codex"] unless codex.empty?

    [nil, nil]
  end

  # The bare session id, "" when the environment names none.
  def id(env = ENV)
    identity(env).first.to_s
  end
end
