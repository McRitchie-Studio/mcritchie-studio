# frozen_string_literal: true

# GhAuthRetry — mint-once-and-retry for a `gh` call that failed on authentication.
#
# WRITES ARE NOT THE ONLY VICTIM. This module was born for `gh pr create`/`pr merge`,
# but the same expiry blinds READS: bin/lib/ci_status.rb read CI through the ambient
# credential and reported :unreadable — withholding the fast cert and, worse, taking
# the REVIEW gate's authoritative CI verdict offline where nobody re-reads it. Reads
# fail QUIETER than writes, which is what let it run for weeks.
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
require "open3"
require_relative "gh_identity"
require_relative "bounded_command"
require_relative "auth_refresh"

module GhAuthRetry
  # The identity is NOT hardcoded here. It used to be (`ITEM = "github.mcritchie-agent"`,
  # plus an `identity: "agent"` default that every caller took), which meant a SHIP
  # session's recovery re-authenticated as the BUILD/REVIEW App. No 403 ever resulted
  # — both Apps hold `checks: read` and the ship lane only reads check-runs — so the
  # behaviour looked fine while the AUDIT TRAIL quietly crossed lanes: the deployer's
  # reads were attributed to mcritchie-agent[bot]. Lane resolution now lives in
  # bin/lib/gh_identity.rb and is shared with bin/gh-token and bin/gh-auth-refresh,
  # so all three agree on which App speaks for this session.

  # gh's wording for "your credential cannot do this write". Matched on the SHAPE of
  # the refusal rather than one exact sentence, because gh phrases it differently per
  # verb (`createPullRequest`, `mergePullRequest`, …) and a missed match costs the
  # whole recovery.
  # NOT /x — extended mode strips the literal spaces, so "resource not accessible"
  # would compile as "resourcenotaccessible" and match nothing. (Caught by the
  # verbatim-real-strings test below, which is why it uses gh's actual output.)
  AUTH_FAILURE = /resource not accessible|bad credentials|authentication failed|gh auth login|requires authentication/i

  # A 403 PERMISSION refusal, not a stale credential (Carl's review of
  # secret-refresh-on-auth-failure). "Resource not accessible by integration" means
  # the App token is LIVE and the installation lacks the grant: a fresh token for the
  # same App fails the same way (docs/agents/modules/source-control.md), so it must
  # not start a refresh. It still matches AUTH_FAILURE, which other readers use to
  # word their error; only the refresh decision (#refreshable?) leaves it out.
  # "...by personal access token" is different: gh fell back to the stored PAT,
  # and a minted App token fixes it, so that one still refreshes.
  PERMISSION_REFUSAL = /not accessible by integration/i

  module_function

  # Seconds one forced mint may take: the broker's own 1Password read is bounded
  # inside it (OpMeter), and this bounds the broker.
  MINT_DEADLINE = 120

  # TRUE when `output` is gh refusing on credentials rather than failing on the work.
  # A non-auth failure (merge conflict, missing branch, red required check) must NOT
  # trigger a mint — re-running those with a fresh token just fails again, slower.
  def auth_failure?(output)
    AUTH_FAILURE.match?(output.to_s)
  end

  # TRUE when a fresh token could change the answer: a credential refusal that is
  # not a permission refusal (PERMISSION_REFUSAL). The one test the refresh paths
  # use (#with_refresh, CiStatus.gh_auth_refusal?).
  def refreshable?(output)
    auth_failure?(output) && !PERMISSION_REFUSAL.match?(output.to_s)
  end

  # A fresh App installation token, or nil when one cannot be minted (no 1Password,
  # not authenticated, mint script missing). nil is a normal outcome: the caller then
  # reports gh's ORIGINAL error, which is the honest thing to show.
  # ACQUISITION LIVES IN bin/gh-token, NOT HERE. This module decides WHEN a call
  # needs a fresh token (the classifier above); bin/gh-token decides HOW to get one
  # — cache with two toggled slots per identity, newest-wins, mint on miss. Keeping
  # them separate is what let a THIRD caller (bin/pr-review) be fixed by wiring
  # rather than by a third copy of the same code.
  #
  # TEST SEAM: GH_AUTH_TOKEN_BIN swaps the broker for a stub, so the failure branch
  # is reachable without minting a real production token. That branch shipped with a
  # NameError precisely because it was unreachable from any safe test.
  def token_bin(env: ENV)
    override = env["GH_AUTH_TOKEN_BIN"].to_s.strip
    override.empty? ? File.expand_path("../gh-token", __dir__) : override
  end

  # A usable token for `identity`, or nil. nil is a normal outcome: the caller then
  # reports gh's ORIGINAL error, which is the honest thing to show.
  #
  # `identity` defaults to THIS SESSION'S LANE rather than to "agent": a ship session
  # (GH_APP_ITEM=github.mcritchie-admin) recovers as the deployer, a build/review
  # session as the agent. A caller that genuinely requires one specific App still
  # names it and wins.
  def mint(root: nil, env: ENV, identity: nil)
    bin = token_bin(env: env)
    return nil unless File.executable?(bin)

    resolved = GhIdentity.resolve(identity, env: env)
    if resolved.nil?
      # An unreadable instruction must not silently become `agent` — that fallback IS the
      # privilege-boundary bug. Two things land here (an unknown GH_APP_ITEM, and a caller
      # that named an identity and passed an empty one) and they are fixed at different
      # knobs, so the reason is derived from what this call actually passed.
      @last_error = GhIdentity.unresolved_reason(identity, env: env)
      return nil
    end

    # --force, ALWAYS. This method is only ever reached because gh just REFUSED a
    # credential, so the cache is the one place a usable token cannot be assumed to
    # be. Without it the broker happily returns the very token that was refused
    # whenever that token is still inside its 50-minute freshness window — a revoked
    # installation, a permissions change, or a future-dated created_at then wedges
    # EVERY ship and EVERY reviewer merge until the window elapses, which is exactly
    # the outage this module exists to end. Forcing also self-heals the cache: the
    # fresh token lands in the inactive slot and wins the newest-by-created_at read
    # for every later process. The cost is one mint on a recovery that would have
    # been served from cache — seconds, by the broker's own stated economics.
    # The broker reads 1Password, and `op` can hang (2026-10-21, 2026-10-27):
    # bounded, with the broker's whole process group killed at the deadline.
    out, err, status = BoundedCommand.capture3(env.to_h, bin, "--identity", resolved, "--force",
                                               deadline: MINT_DEADLINE, chdir: (root || Dir.pwd))
    err = "#{err}\n#{bin} gave no answer within #{MINT_DEADLINE}s and was killed" if status.timed_out?
    token = out.to_s.strip
    unless status.success? && !token.empty?
      # DO NOT swallow this. A misconfigured PEM or a lapsed 1Password session
      # reports the actionable reason here; discarding it leaves the operator with
      # "could not mint" and nothing to act on.
      @last_error = err.to_s.strip
      return nil
    end

    token
  rescue StandardError => e
    @last_error = "#{e.class}: #{e.message}"
    nil
  end

  # ONE `gh` call with the shared refresh (bin/lib/auth_refresh.rb): the block runs
  # with +token+ (nil = the ambient login) and returns [output, ok]. When the output
  # is a credential refusal (refreshable?: not a 403 permission refusal), a token is minted fresh (bin/gh-token
  # --force reads the App key from 1Password; the refused cached token is never
  # handed back), and the block runs once more with it. The refresh is logged as
  # `auth-refresh` with via `github:<App item>` (bin/op-reads), never the token.
  #
  # Raises AuthRefresh::RefreshFailed when no token can be minted and
  # AuthRefresh::StillRefused when GitHub refuses the fresh one too; both carry the
  # refused [output, ok] as #result, so the caller can still print what gh said.
  def with_refresh(identity: nil, root: nil, env: ENV, token: nil, say: nil, &block)
    resolved = GhIdentity.resolve(identity, env: env)
    item = resolved ? GhIdentity.item_for(resolved) : nil
    AuthRefresh.run(item: item || "github", service: "github", env: env, say: say,
                    how: "minting a GitHub App token from a fresh 1Password read",
                    read: -> { token },
                    refresh: lambda {
                      fresh = mint(root: root, env: env, identity: identity)
                      raise StandardError, (last_error.empty? ? "1Password unavailable?" : last_error.lines.last.to_s.strip) unless fresh

                      fresh
                    },
                    rejected: ->(result) { !result[1] && refreshable?(result[0]) },
                    mark: ->(outcome) { mark_refusal(resolved, outcome, env) },
                    &block)
  end

  # A second refusal marks the cache entry (github.<identity>), so `bin/secret
  # status` names the bad App item; an accepted refresh clears it. Loaded lazily:
  # the secret cache needs lib/, and this file also runs from a bin/ tree carried
  # alone (CiStatus in a relocated checkout), where the mark is simply skipped.
  def mark_refusal(identity, outcome, env)
    return unless identity

    require_relative "secret_cache"
    name = "github.#{identity}"
    outcome == :still_refused ? SecretCache.record_refused!(name, "github", env: env) : SecretCache.clear_refused!(name, env: env)
  rescue LoadError, StandardError
    nil
  end

  # Why the most recent acquisition failed, or "" — surfaced by the caller, never
  # the token.
  def last_error
    @last_error.to_s
  end
end
