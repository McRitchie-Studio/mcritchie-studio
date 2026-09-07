# frozen_string_literal: true

require_relative "claim_holder"

# ReviewVerdictGate — only the reviewer who OWNS the verdict may spend the task's
# bounce.
#
# ═══ THE INCIDENT (2026-09-07, turf-monster PR 594) ═══
#
# A pr-review primary (Carl) held the review claim on `interpreter-names-wrong-modal`
# and summoned a domain LIGHT per carl/sops/pr-review-light.md. The light ran
# `bin/task block --kind rework` on its own initiative, then reported back to its Carl
# as though it had only filed a scout report — its report closed with "Your call as
# owner." while the block was ALREADY on the board.
#
# The two-bounce circuit breaker is a SCARCE, TASK-SCOPED resource. The light spent
# the task's ONE bounce, so when the OWNING Carl composed his own block minutes later
# `bin/task block` REFUSED him (bounces exit 10, TRIPPED). The owner was locked out of
# his own verdict by his own assistant, and the block cleared the review claim
# mid-review.
#
# THE COST IS NOT BOOKKEEPING. The breaker routes a TRIPPED task to "merge, or escalate
# to the operator" — so a budget drawn down by a non-owner can push a task to
# ESCALATION without a primary ever having blocked it, and locks the one agent who
# holds the verdict out of recording it.
#
# THE GAP IS ENFORCEMENT, NOT DOCUMENTATION. pr-review-light.md already says the light
# does not drive the verdict, and the light in the incident was additionally briefed in
# its prompt with the prohibition spelled out. Prose did not hold, so the rule moves to
# where it cannot be walked around: the write itself.
#
# ═══ WHY THIS IS KEYED ON THE SOUL AND NOT ON THE LEASE ═══
#
# The obvious fix — "require that the caller HOLD the review lease" — cannot see this
# bug, and the distinction is the whole reason this file exists.
#
# A lease identifies a LIVE INSTANCE: SessionIdentity = CLAUDE_CODE_SESSION_ID plus a
# nonce anchored to the `claude` CLI PROCESS (bin/lib/session_identity.rb). A light is a
# SUBAGENT of its primary's session — same session id, same `claude` ancestor process,
# therefore the SAME NONCE. Measured 2026-09-07 by reading both out of a live subagent.
# ClaimLease.evaluate grades such a caller `:same_instance` and waves it through, so a
# gate written on the lease would have been GREEN on the exact incident that motivated
# it.
#
# What actually separates a light from its primary is the SOUL, and the review claim
# has recorded one since the crew seat rode the claim: TaskReviewClaim#holder_agent,
# published as holder["agent"]. Every review path fills it — the SOPs claim with
# `--agent carl`, and ReviewClaimCli falls back to the session's acting agent — so it is
# the one fact present at review time that tells the owner from the assistant.
#
# ═══ WHAT IT DOES NOT DO ═══
#
# This is a gate against an HONEST SLIP, which is what the incident was: the light acted
# openly under its own soul and reported what it had done. It is NOT proof against a
# caller who passes `--agent <the owner's soul>` to impersonate them. That is the
# studio's standing honor-system posture (TaskReviewClaim: "Enforcement is cooperative"),
# and pretending otherwise here would be a false guarantee. The gate closes the path an
# agent takes by accident; it does not close the one an agent would have to lie to take.
#
# PURE. Nothing here reads the clock, the board, the environment, or the process tree —
# every fact arrives as an argument, so the whole decision table is exercisable at the
# unit tier.
module ReviewVerdictGate
  # ── the verdicts ─────────────────────────────────────────────────────────────
  #
  #   :not_gated     the block spends no bounce (not `rework`) — nothing to protect.
  #   :no_review     no live review claim; there is no verdict owner to usurp.
  #   :owner         the caller IS the recorded verdict owner. Proceed.
  #   :unreadable    the claim could not be read. We know NOTHING, which is not
  #                  permission.
  #   :unattributed  a live review whose claim names no reviewer — nothing can
  #                  establish who owns the verdict.
  #   :foreign       a live review owned by a DIFFERENT soul. THE INCIDENT.
  NOT_GATED = :not_gated
  NO_REVIEW = :no_review
  OWNER = :owner
  UNREADABLE = :unreadable
  UNATTRIBUTED = :unattributed
  FOREIGN = :foreign

  # Verdicts on which the block proceeds. A POSITIVE allowlist, the same shape
  # ClaimHolder::STEALABLE uses and for the same reason: a verdict added later must be
  # admitted ON PURPOSE rather than inherited by falling outside a blacklist.
  ALLOWED = [NOT_GATED, NO_REVIEW, OWNER].freeze

  # The block kinds that SPEND A BOUNCE, and therefore the only ones gated here.
  # `dependency` IS the escalation the breaker routes a deadlock to and `environment`
  # is a blocked desk, not a send-back; neither is countable, and gating either would
  # take the escalation away from the agent most likely to need it. This list must stay
  # in step with BounceLedger's countable kinds — a test pins the two together.
  GATED_KINDS = %w[rework].freeze

  module_function

  # The verdict, from three facts.
  #
  #   kind    the block kind the caller asked for.
  #   holder  the review-claim descriptor, TRI-STATE exactly as bin/task's
  #           `review_holder` returns it: `{}` (no "live" key) means WE GOT NO ANSWER,
  #           `{"live" => false}` means the board says nobody is reviewing, and a hash
  #           with `"live" => true` names a reviewer in `"agent"`.
  #   actor   the soul this block would be attributed to (bin/task's
  #           `resolved_block_actor`).
  #
  # THE TRI-STATE IS THE POINT, and a caller must never collapse it. Reading a failed
  # read as `{"live" => false}` turns a board hiccup into "no review in flight" and
  # hands the bounce to anyone who asks — the same silent-zero the bounce ledger raises
  # on rather than counting, one seam out.
  def verdict(kind:, holder:, actor:)
    return NOT_GATED unless GATED_KINDS.include?(kind.to_s.strip)

    holder = {} unless holder.is_a?(Hash)
    return UNREADABLE unless holder.key?("live")
    return NO_REVIEW unless holder["live"] == true

    owner = soul(holder["agent"])
    return UNATTRIBUTED if owner.empty?

    owner == soul(actor) ? OWNER : FOREIGN
  end

  # May the block proceed on this verdict?
  def allowed?(verdict) = ALLOWED.include?(verdict)

  # A soul slug, normalized for comparison. Slugs are lowercase-with-hyphens by
  # contract (`--agent turf-monster`), so case and surrounding space are noise; nothing
  # else is folded, because `turf_monster` is a DIFFERENT string the fast lane already
  # refuses rather than a spelling of the same soul.
  def soul(value) = value.to_s.strip.downcase

  # ── the refusal ──────────────────────────────────────────────────────────────
  #
  # Returns an ARRAY OF LINES so the caller prefixes them in its own house style, the
  # same contract ClaimHolder.refusal uses.
  #
  # Every branch states the same three things in the same order — WHAT is refused, WHO
  # owns the verdict, and the ONE next move — because the reader this protects is a
  # subagent that has just been told "no" and will otherwise invent its own way
  # forward. The light in the incident had already been told in prose; a refusal that
  # only repeats the prohibition without naming the legitimate path is how that
  # happens again.
  def refusal(verdict, slug:, actor:, holder: {})
    holder = {} unless holder.is_a?(Hash)
    owner = holder["agent"].to_s.strip
    caller_name = actor.to_s.strip.empty? ? "this caller (no soul resolved)" : actor.to_s.strip

    case verdict
    when FOREIGN then foreign_lines(slug, caller_name, owner, holder)
    when UNATTRIBUTED then unattributed_lines(slug, caller_name)
    else unreadable_lines(slug, caller_name)
    end
  end

  def foreign_lines(slug, caller_name, owner, holder)
    ["#{caller_name} does not hold the verdict on #{slug} — #{owner} does.",
     "     review claim: #{owner}#{session_clause(holder)} · #{lease_clause(holder)}",
     "",
     "     The two-bounce circuit breaker is a SCARCE, TASK-SCOPED resource and it belongs to",
     "     the reviewer who OWNS the verdict. A send-back spent by anyone else draws down a",
     "     budget they do not hold: #{owner} is then REFUSED their own block (bounces exit 10,",
     "     TRIPPED), and this task can reach escalation without its reviewer ever blocking it.",
     "",
     "     IF YOU ARE A LIGHT REVIEWER, this is your seam. Your finding goes back to the",
     "     primary who summoned you as a SCOUT REPORT — they hold the verdict, you do not",
     "     spend it. Report the finding and let #{owner} decide; that is the whole role.",
     "",
     "     Recording it WITHOUT spending the bounce (any reviewer may do this):",
     "       bin/task note #{slug} --comment \"<your finding>\"",
     "",
     "     If you ARE #{owner} and the actor simply resolved wrong, re-run naming yourself:",
     "       bin/task block #{slug} --kind rework --agent #{owner} --summary \"...\" --feedback \"...\"",
     "     If the review is finished, its holder releases it (they run it, from their session):",
     "       bin/task review-claim release #{slug}"]
  end

  def unattributed_lines(slug, caller_name)
    ["#{slug} is under a LIVE REVIEW whose claim names NO reviewer, so nothing can",
     "     establish who owns the verdict — and #{caller_name} cannot be shown to.",
     "",
     "     This refuses rather than guesses. A bounce is spent once, and spending it on a",
     "     verdict nobody is recorded as owning is exactly the draw-down this gate exists to",
     "     stop; a wrong refusal costs one re-run, and this one has a one-line fix.",
     "",
     "     The REVIEWER re-acquires the claim naming themselves (same instance, so this",
     "     renews rather than takes over — it does not disturb the review):",
     "       bin/task review-claim acquire #{slug} --agent <their-soul>",
     "     Then the block proceeds as normal. Who holds it right now:",
     "       bin/task review-claim status #{slug}"]
  end

  def unreadable_lines(slug, caller_name)
    ["could not read the review claim for #{slug}, so it cannot be established whether a",
     "     reviewer owns the verdict — and #{caller_name} cannot be shown to.",
     "",
     "     UNKNOWN IS NOT CLEAR. This is the posture the bounce ledger already takes one seam",
     "     over: an unreadable read RAISES rather than counting zero, because a board that",
     "     did not answer has told us nothing. Reading it as \"nobody is reviewing\" would hand",
     "     the bounce to whoever asked during the one moment the board was down.",
     "",
     "     It costs you nothing you did not already owe: this block needs the same board and",
     "     the same token to write. Fix the read and re-run —",
     "       bin/task review-claim status #{slug}"]
  end

  # `· session …b91b`, or nothing when the board named none. Abbreviated through
  # ClaimHolder so this refusal and every other claim message shorten a session id
  # identically.
  def session_clause(holder)
    session = holder["session"].to_s.strip
    session.empty? ? "" : " · session #{ClaimHolder.short_session(session)}"
  end

  # The lease's freshness, stated as a verdict rather than a raw stamp — the one
  # rendering rule ClaimHolder.render_lease exists to keep. This descriptor is the
  # holder_info SHAPE (published `expires_at`), not the claim_hash shape, so it is
  # translated rather than passed through.
  def lease_clause(holder)
    expires = holder["expires_at"].to_s.strip
    return "LIVE" if expires.empty?

    ClaimHolder.render_lease({ "claimed_session" => holder["session"].to_s,
                               "claim_expires_at" => expires })
  end
end
