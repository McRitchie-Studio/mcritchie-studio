# frozen_string_literal: true

# GhAuthRetry — mint-once-and-retry for a `gh` write that failed on authentication.
#
# WHY THIS EXISTS. The 2026-07-29 org migration RETIRED personal access tokens:
# every repo now lives under McRitchie-Studio and `gh` writes authenticate as a
# GitHub App installation token, minted per session by bin/gh-app-mint-token with a
# ~1h TTL. The ambient `gh` login still WORKS for reads, so nothing looks broken
# until the one call that matters — `gh pr create` / `gh pr merge` — comes back
# "Resource not accessible by personal access token". On 2026-08-10 that failure hit
# EVERY ship and EVERY reviewer merge in a single night; each one was recovered by
# hand-exporting a freshly minted token and re-running. This module is that recovery,
# performed once, in-process.
#
# WHAT IT DELIBERATELY IS NOT. Not a credential store and not a login: it mints a
# short-lived installation token, hands it to ONE retried subprocess through its
# environment, and forgets it. It is a RECOVERY path, not an auth strategy — a call
# that succeeds never mints, and a failure that is not an auth failure is returned
# untouched so the caller still sees the real error.
#
# THE TOKEN IS NEVER PRINTED. It is passed by env to the retried child and never
# echoed, logged, or written to disk. `mint` reads the App credentials through the
# operator's 1Password CLI exactly as docs/agents/modules/credentials.md prescribes.
module GhAuthRetry
  # The App identity the BUILD/REVIEW lanes use. Deliberately NOT the deployer
  # identity (which cannot open or merge PRs by design — that separation is the
  # point, not a bug; see docs/agents/modules/credentials.md → GitHub).
  ITEM = "github.mcritchie-agent"
  APP_ID_REF = "op://agents/#{ITEM}/app-id"
  PEM_REF = "op://agents/#{ITEM}/mcritchie-agent.2026-07-29.private-key.pem"
  OP_BIN = "/opt/homebrew/bin/op"

  # gh's wording for "your credential cannot do this write". Matched on the SHAPE of
  # the refusal rather than one exact sentence, because gh phrases it differently per
  # verb (`createPullRequest`, `mergePullRequest`, …) and a missed match costs the
  # whole recovery.
  # NOT /x — extended mode strips the literal spaces, so "resource not accessible"
  # would compile as "resourcenotaccessible" and match nothing. (Caught by the
  # verbatim-real-strings test below, which is why it uses gh's actual output.)
  AUTH_FAILURE = /resource not accessible|bad credentials|authentication failed|gh auth login|requires authentication/i

  module_function

  # TRUE when `output` is gh refusing on credentials rather than failing on the work.
  # A non-auth failure (merge conflict, missing branch, red required check) must NOT
  # trigger a mint — re-running those with a fresh token just fails again, slower.
  def auth_failure?(output)
    AUTH_FAILURE.match?(output.to_s)
  end

  # A fresh App installation token, or nil when one cannot be minted (no 1Password,
  # not authenticated, mint script missing). nil is a normal outcome: the caller then
  # reports gh's ORIGINAL error, which is the honest thing to show.
  def mint(root: nil, env: ENV)
    mint_bin = File.expand_path("../gh-app-mint-token", __dir__)
    return nil unless File.executable?(mint_bin)

    app_id = read_secret(APP_ID_REF, env: env)
    pem = read_secret(PEM_REF, env: env)
    return nil if app_id.to_s.strip.empty? || pem.to_s.strip.empty?

    token = IO.popen({ "GH_APP_ID" => app_id.strip, "GH_APP_PEM" => pem },
                     [mint_bin], chdir: (root || Dir.pwd), err: File::NULL, &:read).to_s.strip
    return nil unless $?.success? && !token.empty?

    token
  rescue StandardError
    nil
  end

  # Read one 1Password reference. Returns "" on any failure so `mint` degrades to nil
  # rather than raising inside a ship that is otherwise fine.
  def read_secret(ref, env: ENV)
    return "" unless File.executable?(OP_BIN)

    out = IO.popen(env.to_h, [OP_BIN, "read", ref], err: File::NULL, &:read).to_s
    $?.success? ? out : ""
  rescue StandardError
    ""
  end
end
