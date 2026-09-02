# frozen_string_literal: true

require "time"
require_relative "claim_lease"

# ClaimHolder — WHO holds this task, in WHAT ROLE, and HOW FRESH is their lease.
#
# ClaimLease (its sibling, and the only thing this file leans on) answers one
# question: may THIS instance write? Its verdict is `:held_by_other` and nothing
# more. Every consumer then has to turn that verdict into a sentence for a human,
# and that sentence is where the bug lived.
#
# ═══ THE NEAR-MISS, 2026-09-01 ═══
#
# `bin/ship ship-waiter-misreports-ci` refused, verbatim:
#
#   task … is claimed by a DIFFERENT live instance (session …, instance …, last
#   heartbeat ~Ns ago, lease TTL 120s). Ship must not hand off another builder's
#   work — take the task over first (bin/task begin <slug> --steal) …
#
# Every fact in it was true and the sentence was still wrong, because it names a
# role it never checked. "another builder's work" describes a RIVAL BUILDER, and
# `--steal` is that case's correct remedy — it is what the flag was designed for.
# The actual holder was a REVIEWER.
#
# THE COST OF GETTING THE ROLE WRONG IS NOT A WRITE RACE. Two builders racing cost
# a rebase. Stealing a task mid-review costs the REVIEW:
#
#   * it VOIDS THE NO-SELF-REVIEW GUARANTEE for that review. The steal transfers
#     the build claim and stamps the stealer into the author set; the review that
#     was in flight against the previous author is now a review of work its own
#     claimant may have written.
#   * it STRANDS THE REVIEWER'S VERDICT. A reviewer with a live claim is part-way
#     through gates whose conclusions are simply discarded — no bounce, no block,
#     no record that a review was in progress at all.
#
# Neither of those is recoverable by re-running anything, and neither is visible
# afterwards. So the routing here is deliberately LOPSIDED, the same shape
# ClaimLease.abandoned? uses: a live review routes to ASK, an UNKNOWN routes to
# ASK, and only a positively-established absence of review routes to `--steal`.
#
# The session that hit this read the refusal, nearly passed `--steal`, and instead
# spent ninety seconds asking the holder — who turned out to be a reviewer. The
# whole cost of the bug is that those ninety seconds were the thing the message
# steered away from.
#
# ═══ THE COMPOUNDING CAUSE: A LEASE RENDERED WITHOUT ITS FRESHNESS ═══
#
# The same near-miss carried a second defect, and fixing either alone fixes half a
# bug. `bin/task show --verbose` printed
#
#   claim: session <id> · expires 2026-09-02T04:12:26Z
#
# at 04:14:28Z — two minutes AFTER that timestamp. An expired lease rendered
# identically to a live one, so the reader sampled it twice, read agreement, and
# concluded "live". Meanwhile `review-claim status` answered "not under review"
# for the same task at the same moment.
#
# A raw timestamp is not a freshness report; it is homework. So `render_lease`
# below is the ONE rendering of a lease that every surface prints — the display
# AND the refusal — and it states the VERDICT (LIVE / EXPIRED / UNVERIFIABLE) with
# the remaining or elapsed time already worked out. A corrected display sitting
# above a refusal that still implies a healthy holder with three seconds of lease
# left would leave the reader exactly as misled.
#
# ═══ WHY OBSERVATION IS A COMMAND AND NOT A DISCIPLINE ═══
#
# `observe` (below) exists because two independent sessions, on the same day,
# were told to "sample the lease twice" and both concluded the question was
# unanswerable. Sampling twice makes a reader look for AGREEMENT, and two samples
# of a live lease agree about the STATE every time. The interesting fact is that
# they DISAGREE about the NUMBER.
#
# Differencing `claim_expires_at` across two reads does answer it:
#
#   expiry MOVED     → something is renewing → a live holder
#   expiry UNCHANGED → nothing renewed in that window → dying or already dead
#   expiry PAST      → lapsed; the task is free
#
# And a single read cannot substitute, however carefully it is read: 74s into a
# 120s TTL looks identical whether the holder renews at 90s or never again. That
# is why this is arithmetic a COMMAND performs, not a rule a tired reader is asked
# to remember.
#
# PURE. Nothing here reads the clock, the board, the environment, or the process
# tree — every fact arrives as an argument, so the whole decision table is
# exercisable at the unit tier and the same source answers bin/ship, bin/task, and
# bin/task review-claim.
module ClaimHolder
  # --- lease freshness ---------------------------------------------------------
  #
  # The four states a stored lease can be in, as a VERDICT rather than a timestamp.
  # `:expired` and `:unverifiable` are deliberately distinct (ClaimLease draws the
  # same line): a lapsed lease is free, an ungrammatical one is merely uncheckable,
  # and collapsing them would let "we could not read it" render as "nobody holds it".
  NONE = :none
  LIVE = :live
  EXPIRED = :expired
  UNVERIFIABLE = :unverifiable

  # --- observed renewal --------------------------------------------------------
  #
  # What differencing two reads of `claim_expires_at` OBSERVED. These are reports of
  # evidence, not guesses: each one names a fact that was seen.
  #
  #   :free          nothing held it, or its lease had already lapsed when we looked.
  #   :renewing      the expiry MOVED between reads — a holder is alive and renewing.
  #   :lapsed        the expiry never moved and we outlasted it. Definitive: free now.
  #   :not_renewing  the expiry never moved across a window longer than a full renew
  #                  cycle. The holder is not heartbeating; the lease will lapse on
  #                  its own at the recorded expiry.
  #   :inconclusive  the expiry did not move, but we did not watch long enough for
  #                  that to mean anything. Reported as ignorance, never as absence.
  #   :unobserved    only one read was taken (--no-observe). Says so rather than
  #                  dressing a single sample up as an observation.
  FREE = :free
  RENEWING = :renewing
  LAPSED = :lapsed
  NOT_RENEWING = :not_renewing
  INCONCLUSIVE = :inconclusive
  UNOBSERVED = :unobserved

  # Grades on which a lease may be treated as available. Stated as a positive
  # allowlist so a grade added later must be admitted on purpose rather than
  # inherited by falling outside a blacklist.
  OBSERVED_FREE = [FREE, LAPSED].freeze

  # --- holder role -------------------------------------------------------------
  #
  #   :reviewing  a live review is in flight on this task → ASK, never steal.
  #   :building   no review is in flight → the holder is a builder; `--steal` is the
  #               remedy it was designed for.
  #   :unknown    we could not establish either way (an older board, an unreadable
  #               record). Routes with :reviewing, because the cost of a wrong steal
  #               is unrecoverable and the cost of a wrong ask is a question.
  REVIEWING = :reviewing
  BUILDING = :building
  UNKNOWN = :unknown

  # Roles on which `--steal` is the correct next move. Positive allowlist, same
  # reason as OBSERVED_FREE: an unknown must never inherit the steal route.
  STEALABLE = [BUILDING].freeze

  module_function

  # The state of a stored lease relative to `now`. Mirrors ClaimLease's own
  # vocabulary rather than re-deciding it: `live?` merges "confirmed fresh" with
  # "unverifiable", and this splits them back out so a message can tell the reader
  # which one it actually has.
  def lease_state(claim, now: Time.now)
    claim ||= {}
    return NONE if claim["claimed_session"].to_s.strip.empty?
    return UNVERIFIABLE if ClaimLease.corrupt_expiry?(claim)

    expires = ClaimLease.parse_time(claim["claim_expires_at"])
    # A BLANK expiry is :expired territory in ClaimLease (the renewer always writes
    # one, so blank is a never-renewed relic) and is reported as such here.
    return EXPIRED if expires.nil? || expires <= now

    LIVE
  end

  # Seconds of lease left (positive) or seconds since it lapsed (negative). nil when
  # there is no parseable expiry to measure from. The number the display and the
  # refusal both need, computed once.
  def lease_seconds(claim, now: Time.now)
    expires = ClaimLease.parse_time((claim || {})["claim_expires_at"])
    return nil if expires.nil?

    (expires - now).round
  end

  # THE ONE RENDERING OF A LEASE'S FRESHNESS. Every surface that states a lease
  # prints this string: `bin/task show --verbose`'s claim line, bin/ship's refusal,
  # and bin/task's build-claim gate.
  #
  # It is one function for the reason ClaimLease.humanize_age is one function — the
  # board saying "2h" while the gate says "120m" is a small version of exactly the
  # confusion this file exists to end, and a display that marked expiry sitting above
  # a refusal that did not would be a large one.
  def render_lease(claim, now: Time.now)
    claim ||= {}
    stamp = claim["claim_expires_at"].to_s.strip
    case lease_state(claim, now: now)
    when NONE then "none"
    when UNVERIFIABLE
      "UNVERIFIABLE expiry #{stamp.inspect} — cannot be ruled lapsed, so it is treated as held"
    when EXPIRED
      seconds = lease_seconds(claim, now: now)
      return "EXPIRED · no expiry was ever recorded — never renewed, free to claim" if seconds.nil?

      "EXPIRED · lapsed #{ClaimLease.humanize_age(-seconds)} ago (#{stamp}) — free to claim"
    else
      "LIVE · lapses in #{ClaimLease.humanize_age(lease_seconds(claim, now: now))} (#{stamp})"
    end
  end

  # The holder's ROLE, from TWO facts, neither of which is sufficient alone.
  #
  #   review_in_progress  the board's own published column. Cheap (it is already on
  #                       the task payload every consumer read to get here) but
  #                       STAGE-SCOPED: Task#review_in_progress? is false unless the
  #                       task is `submitted`, so a task bounced back to `building`
  #                       under a still-live review lease answers false.
  #   review_claim_live   the review LEASE itself (TaskReviewClaim#live?). Authoritative
  #                       about a reviewer at any stage, and one extra read.
  #
  # BOTH ARE TRI-STATE, and every caller must keep them that way: true, false, and
  # nil for "we did not get an answer" (an older board, a failed read, a payload
  # that omits the key). Reading a missing fact as `false` is the fail-open that
  # would put an unknown back on the steal route — the one direction this file may
  # never fail in.
  #
  # THE FOLD IS LOPSIDED, the same shape ClaimLease.abandoned? uses: EITHER fact
  # saying yes is a review, only BOTH saying no is a build, and anything else is an
  # unknown that routes with the reviewer. The asymmetry is the whole argument of
  # this file — a wrong "builder" costs a stranded verdict nobody can reconstruct, a
  # wrong "reviewer" costs a question.
  #
  # THE ROUTING IS ON THE TASK, NOT ON THE SESSION. A live review anywhere on this
  # task routes to ASK, whether or not the reviewer's session is the one holding the
  # build lease. Both shapes occur — a reviewer whose status line renews the build
  # claim it touched, and a genuinely separate builder and reviewer — and stealing
  # the build claim strands the verdict in BOTH. Whose session is whose is reported
  # as a fact by `session_relation` below; it never changes the route.
  def role(review_in_progress:, review_claim_live: nil)
    return REVIEWING if review_in_progress == true || review_claim_live == true
    return BUILDING if review_in_progress == false && review_claim_live == false

    UNKNOWN
  end

  # Is `--steal` the right next move for this role?
  def stealable?(role) = STEALABLE.include?(role)

  # How the two claims relate, for the refusal to state plainly. Returns nil when
  # either side is unknown — an unstated relation is better than a guessed one.
  def session_relation(holder_session, reviewer_session)
    holder = holder_session.to_s.strip
    reviewer = reviewer_session.to_s.strip
    return nil if holder.empty? || reviewer.empty?

    holder == reviewer ? :same_session : :different_sessions
  end

  # `…9c1` — the last four of a session id, the form every claim message already
  # uses. Kept here so the refusal and the display abbreviate identically.
  def short_session(session)
    text = session.to_s.strip
    return "-" if text.empty?

    "…#{text[-4..] || text}"
  end

  # --- the observation ---------------------------------------------------------

  # What two reads of one lease OBSERVED. Pure arithmetic over the two expiry
  # stamps and the wall time spent between them.
  #
  #   first_expires_at   the expiry read at `first_read_at` (nil ⇒ nothing held)
  #   second_expires_at  the expiry read at `now` (nil ⇒ the claim was released)
  #   renew_interval     the holder's renewal cadence, in seconds. REQUIRED, with no
  #                      default on purpose: the whole verdict :not_renewing rests on
  #                      having watched longer than one renewal cycle, and a caller
  #                      that inherited a wrong cadence from a default would get a
  #                      confident answer built on the wrong number. bin/lib's
  #                      ShiftRenewer::INTERVAL_SECONDS is the cadence every lease on
  #                      this machine is renewed at; pass that.
  #
  # AN EXPIRY THAT MOVED BACKWARDS is folded in with "unchanged" rather than given a
  # state of its own. It means the row was released and re-taken between reads, which
  # is a change of hands and not evidence that THIS holder is renewing — and the
  # conservative reading (do not report a live holder we did not see renew) is the
  # one that keeps a reader asking instead of stealing.
  def observe(first_expires_at:, second_expires_at:, first_read_at:, renew_interval:, now: Time.now)
    first = ClaimLease.parse_time(first_expires_at)
    # Nothing held it, or it had ALREADY LAPSED when we looked. Both are free, and
    # both are answerable from the first read alone — which is why the caller never
    # has to wait for them.
    return FREE if first.nil? || first <= first_read_at

    second = ClaimLease.parse_time(second_expires_at)
    return FREE if second.nil? # released outright between the two reads

    return RENEWING if second > first
    return LAPSED if now >= second # we outlasted the lease and it never moved

    watched = now - first_read_at
    watched > renew_interval ? NOT_RENEWING : INCONCLUSIVE
  end

  # Does this grade mean the task is free to take right now?
  def observed_free?(grade) = OBSERVED_FREE.include?(grade)

  # One sentence per observed grade, stating THE EVIDENCE rather than a conclusion
  # the caller must trust. `expires_at` is the stamp the lease will (or did) lapse at.
  def render_observation(grade, expires_at: nil, watched_seconds: nil, renew_interval: nil)
    stamp = expires_at.to_s.strip
    watched = watched_seconds.nil? ? nil : ClaimLease.humanize_age(watched_seconds)
    case grade
    when FREE
      "FREE — no live claim was found at all; nothing to wait for."
    when RENEWING
      "RENEWING — the expiry MOVED while we watched#{watched ? " (#{watched})" : ""}. " \
        "Somebody is alive and holding this; it will not lapse on its own."
    when LAPSED
      "LAPSED — the expiry never moved and we outlasted it#{stamp.empty? ? "" : " (#{stamp})"}. " \
        "The lease is dead and the task is free."
    when NOT_RENEWING
      "NOT RENEWING — the expiry did not move in #{watched || "the window watched"}, longer than " \
        "the #{renew_interval}s renewal cycle. Nothing is heartbeating this; it lapses on its own" \
        "#{stamp.empty? ? "" : " at #{stamp}"}."
    when INCONCLUSIVE
      "INCONCLUSIVE — the expiry did not move in #{watched || "the window watched"}, which is not " \
        "longer than the #{renew_interval}s renewal cycle, so that proves nothing either way. " \
        "Watch longer (--observe-for) to get an answer."
    else
      "UNOBSERVED — a single read was taken, and a single read cannot tell renewing from dying " \
        "(74s into a 120s TTL looks the same either way). Drop --no-observe for an answer."
    end
  end

  # --- the refusal -------------------------------------------------------------
  #
  # The message a consumer prints when ClaimLease says :held_by_other. Returns an
  # ARRAY OF LINES so each caller can prefix them in its own house style (bin/ship
  # prefixes `ship:`, bin/task prints them bare) without this file guessing.
  #
  # Every branch states the same three things in the same order — WHAT is held, WHO
  # holds it and in what role, and the ONE next move — because the failure being
  # fixed is a reader acting on the remedy line without the role line having ever
  # been checked.
  #
  #   slug             the task
  #   claim            the build-claim hash (ClaimLease.from_devops)
  #   role             `role(...)` above
  #   steal_command    the caller's OWN takeover line, so the operator re-runs the
  #                    path they were on rather than a different one
  #   retry_command    what to re-run once the task is free
  #   reviewer         the reviewing soul's slug, when the board named one
  #   reviewer_session the reviewing session id, when the board named one
  def refusal(slug:, claim:, role:, steal_command:, retry_command:,
              reviewer: nil, reviewer_session: nil, now: Time.now)
    lines = ["task #{slug} is claimed by a DIFFERENT live instance, and that holder is #{headline(role)}."]
    lines << "     build claim: session #{short_session((claim || {})["claimed_session"])}" \
             "  instance #{(claim || {})["claim_nonce"]}  ·  #{render_lease(claim, now: now)}" \
             "#{heartbeat_clause(claim, now: now)}"
    lines << "     review:      #{review_line(role, slug, claim, reviewer, reviewer_session)}"
    lines.concat(remedy(role, slug, steal_command, retry_command))
    lines
  end

  # WHEN THE HOLDER LAST PROVED ITSELF, beside WHEN THE LEASE DIES. They are two
  # readings of one number and both earn their place: the heartbeat age says how
  # recently the holder was demonstrably there, and the lapse time says how long you
  # would have to wait it out. A refusal carrying only the first is the one that read
  # as "healthy live builder" three seconds before the lease expired.
  #
  # Only stated for a LIVE lease. On an expired or unrecorded one the derived age is
  # arithmetic about a lease nobody is renewing, and printing it would dress a dead
  # claim in a liveness signal.
  def heartbeat_clause(claim, now: Time.now)
    return "" unless lease_state(claim, now: now) == LIVE

    age = ClaimLease.heartbeat_age(claim, now: now)
    age.nil? ? "" : "  ·  last heartbeat ~#{age}s ago"
  end

  # The headline verb. UNKNOWN says what it does not know rather than picking the
  # likelier of the two — that guess is the original bug in miniature.
  def headline(role)
    case role
    when REVIEWING then "REVIEWING it"
    when BUILDING then "BUILDING it"
    else "of an UNDETERMINED role"
    end
  end

  def review_line(role, slug, claim, reviewer, reviewer_session)
    case role
    when BUILDING
      "none — no review is in flight on #{slug} and no review lease is held on it"
    when UNKNOWN
      "UNKNOWN — the board did not answer whether #{slug} is under review"
    else
      who = [reviewer.to_s.strip.empty? ? nil : reviewer,
             reviewer_session.to_s.strip.empty? ? nil : "session #{short_session(reviewer_session)}"].compact
      who = ["a live review claim"] if who.empty?
      relation = session_relation((claim || {})["claimed_session"], reviewer_session)
      suffix =
        case relation
        when :same_session then " — the SAME session that holds the build claim"
        when :different_sessions then " — a DIFFERENT session from the build-claim holder"
        else ""
        end
      "#{who.join(" · ")}#{suffix}"
    end
  end

  # THE NEXT MOVE, and the argument for it. The stakes paragraph is repeated in the
  # two non-stealable branches rather than stated once and referenced, because the
  # reader this protects is one who reads the remedy line and stops.
  def remedy(role, slug, steal_command, retry_command)
    case role
    when BUILDING
      ["     Ship must not hand off another builder's work — take the task over first:",
       "       #{steal_command}",
       "     then re-run: #{retry_command}"]
    when REVIEWING
      ["     DO NOT STEAL THIS. Taking a task over mid-review VOIDS THE NO-SELF-REVIEW",
       "     GUARANTEE for that review and STRANDS THE REVIEWER'S VERDICT — their gates'",
       "     conclusions are discarded silently, and the task can then be reviewed by its",
       "     own author. That is not recoverable by re-running anything.",
       "     ASK THE HOLDER TO RELEASE IT instead (they run it, from their session):",
       "       bin/task review-claim release #{slug}",
       "     Not sure the review is still alive? This OBSERVES the lease, it does not guess:",
       "       bin/task review-claim status #{slug}",
       "     Once it is released, re-run: #{retry_command}"]
    else
      ["     DO NOT STEAL UNTIL YOU KNOW. A reviewer's claim is indistinguishable from a",
       "     builder's here, and stealing one voids the no-self-review guarantee for that",
       "     review and strands its verdict. Ask the board — it OBSERVES the lease:",
       "       bin/task review-claim status #{slug}",
       "     A live review  → ask them to release: bin/task review-claim release #{slug}",
       "     No live review → #{steal_command}",
       "     then re-run: #{retry_command}"]
    end
  end

  # The loud line a `--steal` prints when it is overriding a LIVE REVIEW. `--steal`
  # stays available on purpose — the ticket is explicit that it is the correct remedy
  # for the builder case it was written for, and an operator who has already asked
  # must be able to proceed. What it must never do is proceed SILENTLY: this is the
  # same posture bin/task's archive gate takes with `--force`, which names the proof
  # it is waiving so the next reader of the log can see which one was skipped.
  def steal_override_warning(slug, reviewer: nil, reviewer_session: nil)
    who = [reviewer.to_s.strip.empty? ? nil : reviewer,
           reviewer_session.to_s.strip.empty? ? nil : "session #{short_session(reviewer_session)}"].compact
    who = ["an unnamed reviewer"] if who.empty?
    ["⚠  --steal: #{slug} is UNDER LIVE REVIEW by #{who.join(" · ")} and you are taking it anyway.",
     "   This VOIDS THE NO-SELF-REVIEW GUARANTEE for that review and STRANDS its verdict:",
     "   the reviewer's gate conclusions are discarded, and this task can now be reviewed",
     "   by its own author. Tell them — bin/task review-claim release #{slug} is the clean path."]
  end
end
