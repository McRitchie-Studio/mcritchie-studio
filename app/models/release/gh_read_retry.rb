# frozen_string_literal: true

class Release
  # Pure RETRY POLICY for a cheap, idempotent `gh` READ — IO-free and Rails-free,
  # the same contract as GhFailure / SealRetry / ShipSequence (bin/release
  # `require_relative`s this file directly, so it must load standalone).
  #
  # WHY IT EXISTS: A SLEEP IS NOT A REMEDY FOR A DEAD CREDENTIAL.
  #
  # `dispatch_and_watch` takes a pre-dispatch snapshot of the newest run id, and a
  # snapshot that never answers is a HARD REFUSAL — without a baseline the sweep
  # cannot tell its own run from a prior one, so it would read someone else's
  # verdict. That refusal is correct and stays. What was wrong is what happened
  # BEFORE it: five reads, three seconds apart, each one re-running the SAME
  # command with the SAME environment, and then a refusal that discarded gh's own
  # words.
  #
  # MEASURED TWICE on 2026-09-22 (rel-20260922-7210bd and rel-20260922-a299ae),
  # identical text both times, each costing a manual intervention mid-release. The
  # sleep-retry loop was ALREADY THERE and cleared neither — which is itself the
  # diagnosis. A transient that a 12-second window does not clear, and that a hand
  # re-run clears seconds later, is not a blip; it is a credential the process is
  # holding that the operator's shell is not. bin/release inherits `GH_TOKEN` from
  # the shell that launched it, App installation tokens live ~1 hour BY DESIGN, and
  # a sweep runs longer than that — so the ambient token dies MID-RUN while a fresh
  # one sits in the broker's cache that nothing in this lane ever consults.
  # Reproduced against the exact failing call:
  #
  #   GH_TOKEN=<dead> gh run list --workflow qa-deploy.yml --limit 1 --json databaseId
  #   → HTTP 401: Bad credentials … Try authenticating with: gh auth login   (0.24s)
  #
  # identical on every retry, and instant — a sleep can only make it slower.
  #
  # THE POLICY, AND WHY IT SPLITS BY CAUSE. The two failure classes want opposite
  # remedies, and this module's whole job is to stop applying one to the other:
  #
  #   * CREDENTIAL-class (Release::GhFailure.credential_failure? — 401 Bad
  #     credentials, `requires authentication`, `gh auth login`, …): re-mint ONCE
  #     and retry IMMEDIATELY. No sleep: waiting cannot revive a token, and the
  #     seconds are spent for nothing. If the fresh token is ALSO refused, stop —
  #     a second mint of the same identity fails identically (the loop
  #     GhAuthRetry's own header warns about).
  #   * EVERYTHING ELSE (a rate limit, a 5xx, a genuinely unresolvable host): the
  #     existing bounded sleep-retry, unchanged. The read is cheap, idempotent and
  #     read-only, so retrying costs nothing — and this is the class a sleep can
  #     actually clear.
  #
  # A MINT THAT CANNOT BE MADE STOPS THE LOOP rather than burning the remaining
  # attempts. Once the failure is known to be credential-class and no fresh
  # credential is available, every further read is a re-run of a command whose
  # answer is already known, and each one delays the refusal the operator needs to
  # read.
  #
  # THE RECOVERY ATTEMPT IS NOT CHARGED TO THE BUDGET. `attempts:` bounds the reads
  # made against the AMBIENT credential; a re-mint grants one more so a token
  # minted on the final attempt is actually used. A mint nobody spends is the
  # defect this module exists to end, one iteration over.
  #
  # IT DECIDES, IT DOES NOT PERFORM. Reading, sleeping and minting are all injected
  # (the block, `sleeper:`, `minter:`), so every branch above is reachable in a
  # test with no network, no clock and no real token — which is exactly what the
  # branch it replaces could not offer.
  module GhReadRetry
    # Matches the loop this replaces: 5 reads, 3s apart.
    ATTEMPTS = 5
    DELAY_SECONDS = 3

    # ok      — did a read finally succeed?
    # out     — the successful read's output, or the LAST failure's (gh prints its
    #           error body on stdout and its status line on stderr, and bin/release
    #           captures the pair, so this is what the operator must be shown).
    # reads   — how many reads were actually made.
    # token   — the freshly minted credential when one was minted and accepted, so
    #           the caller can carry it to the REST of the lane. A token that
    #           rescued the baseline read and was then dropped would leave the very
    #           next call (the dispatch) failing on the credential just proven dead.
    # cause   — :ok, :credential, :unmintable, :exhausted.
    Result = Struct.new(:ok, :out, :reads, :token, :reminted, :cause, keyword_init: true) do
      def ok?       = ok
      def reminted? = reminted
    end

    module_function

    # Runs the block until a read succeeds or the policy gives up. The block is
    # handed the credential to use (nil = the ambient one) and returns the
    # `[out, ok]` pair `bin/release`'s `sh(..., capture: true)` already produces.
    def call(attempts: ATTEMPTS, delay: DELAY_SECONDS, sleeper: nil, minter: nil)
      token    = nil
      reminted = false
      out      = ""
      reads    = 0
      budget   = attempts

      while reads < budget
        reads += 1
        out, ok = yield(token)
        return result(true, out, reads, token, reminted, :ok) if ok

        unless Release::GhFailure.credential_failure?(out)
          sleeper&.call(delay) if reads < budget
          next
        end

        # Credential-class from here down: sleeping is off the table.
        return result(false, out, reads, token, reminted, :credential) if reminted

        minted = minter ? minter.call.to_s.strip : ""
        return result(false, out, reads, nil, false, :unmintable) if minted.empty?

        token    = minted
        reminted = true
        budget  += 1 # the recovery read is granted, never charged
      end

      result(false, out, reads, token, reminted, :exhausted)
    end

    def result(ok, out, reads, token, reminted, cause)
      Result.new(ok: ok, out: out.to_s, reads: reads, token: token, reminted: reminted, cause: cause)
    end
  end
end
