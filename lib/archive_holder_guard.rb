# frozen_string_literal: true

require_relative "claim_lease"

# ArchiveHolderGuard — refuse to archive a task whose holder we cannot identify.
#
# THE NEAR-MISS (2026-09-01, recorded in docs/agents/system/agent-presence.md as
# cost #1). Mr. McRitchie asked that one session's work be HELD. The session could
# not be identified from disk: its task record carried an app and a MASCOT and
# nothing else. It was resolved only by MESSAGING the peer session and asking who
# it was. Had that session been idle, busy, or unreachable, the work would have
# been archived — and the operator's explicit exception would have protected
# nothing, because the thing it named could not be found.
#
# `archived` is TERMINAL and the work it destroys is UNCOMMITTED. No gate, review,
# or CI ever sees it. That makes a wrong archive strictly worse than a wrong reap:
# a refused reap costs a run, a wrong archive costs an afternoon that no artifact
# can reconstruct.
#
# ═══ THE RULE, AND WHERE IT COMES FROM ═══
#
# bin/lib/cert_orphan_guard.rb already applies this posture to a FAR less
# destructive act. Asked to kill a process it cannot prove is its own, it does not
# guess: it grades the process `:unverifiable`, REFUSES, and NAMES what it could
# not verify, because "a reaper that guesses is worse than no reaper". This file is
# that rule pointed at the more destructive act. It deliberately reuses the guard's
# SHAPE (a positive invariant, a graded decision, every non-proof a refusal that
# names itself) and ClaimLease's LIVENESS (one notion of "is the holder working",
# never a second that can drift from it).
#
# ═══ THE INVARIANT ═══
#
# POSITIVE, asserted — never a blacklist of the ways a task might still be live:
#
#   ARCHIVE ONLY WHAT WE CAN PROVE IS NOT LIVE WORK.
#
# Proof comes in exactly three forms, and everything else is a refusal:
#
#   stage is shipped/archived     → :concluded    The pipeline's own conclusion —
#                                                 the code is on `main` and the
#                                                 desk holds nothing unmerged.
#                                                 ARCHIVE. (This is the lane
#                                                 `bin/release archive` sweeps.)
#   live stage, NO holder signal  → :unheld       No session, no mascot, no claim:
#                                                 nobody ever picked it up.
#                                                 ARCHIVE.
#   live stage, holder NAMED,
#     every channel silent        → :abandoned    A session we CAN check, checked,
#                                                 and provably walked away.
#                                                 ARCHIVE.
#
#   live stage, holder NAMED,
#     lease still live            → :held         REFUSE. Name the session and its
#                                                 heartbeat age.
#   live stage, holder NAMED,
#     a channel still speaks      → :working      REFUSE. Name the channel that
#                                                 spoke.
#   live stage, holder signal
#     names NO checkable session  → :unverifiable REFUSE AND NAME what we hold and
#                                                 what we lack. A human decides.
#                                                 THE NEAR-MISS'S OWN SHAPE.
#
# ═══ WHY :unverifiable IS NOT :unheld — THE WHOLE POINT OF THIS FILE ═══
#
# These two look identical from the archiving side: neither names a session, so
# neither can be checked for liveness. Collapsing them is exactly the bug. A record
# carrying a MASCOT is a record some session FILED — the mascot is that session's
# paint. "Somebody was here and we cannot tell who" and "nobody was ever here" are
# opposite facts that happen to share a missing field, and reading the first as the
# second is how live work gets archived while the log reads clean.
#
# So identity is asked POSITIVELY (IDENTITY_KEYS — a session we could go check),
# and a holder signal with no identity behind it (PAINT_KEYS) is graded as the
# unknown it is. An absence of evidence is never an affirmative negative.
#
# ═══ WHY THE DESK'S ABSENCE IS AN ANSWER AND ITS UNREADABILITY IS NOT ═══
#
# ClaimLease.abandoned? takes `desk_touched: true/false/nil` and treats nil —
# "could not tell" — as protective, which is correct for the heartbeat that asks it
# from INSIDE the desk. Archiving asks from the PRIMARY CHECKOUT, where the desk is
# somewhere else entirely, so the naive wiring hands it nil every single time and
# the gate refuses every archive on the machine. A guard that refuses everything is
# uninstalled within a week, and then it protects nothing.
#
# The fix is to keep the distinction the caller must draw honestly (see
# `desk_touched_for`), and it is the same line DeskGuard#rails_repo? draws:
#
#   the desk directory DOES NOT EXIST → `false`. A REAL answer, not an unknown.
#                                       There is no desk, so there is no
#                                       uncommitted work in one to destroy.
#   the desk exists but cannot be read → `nil`. A genuine unknown. PROTECTS.
#
# Inapplicability is not a soft pass, and unreadability is not silence.
module ArchiveHolderGuard
  # Stages whose work the pipeline has already concluded. Reaching `shipped` means
  # the code is merged to `main`; there is no unmerged work left for an archive to
  # destroy. `archived` is here so a re-archive is idempotent rather than refused.
  CONCLUDED_STAGES = %w[shipped archived].freeze

  # Keys that name a holder we can actually GO AND CHECK. Each resolves to a
  # session id, which is what every liveness channel is keyed on.
  IDENTITY_KEYS = %w[claimed_session session_id mascot_session].freeze

  # Keys that prove SOMEBODY filed this task while naming no session to check. This
  # is the near-miss's record shape exactly: app + mascot, and nothing to ask.
  PAINT_KEYS = %w[mascot agent_slug built_by].freeze

  # Grades on which the archive PROCEEDS. Stated as a positive allowlist so a grade
  # added later must be explicitly admitted rather than silently permitted.
  PERMITTED = %i[concluded unheld abandoned].freeze

  module_function

  # The grade for one task. PURE: every fact is passed in, nothing here reads the
  # clock, the board, the filesystem, or the process table. The CLI gathers the
  # facts (see bin/task's archive_holder_facts) and this decides on them, so the
  # whole decision table is exercisable at the unit tier.
  #
  #   stage:        the task's CURRENT stage, as a string.
  #   devops:       the task's metadata["devops"] hash.
  #   claim_live:   ClaimLease.live?(claim) — a lease we could not rule lapsed.
  #   abandoned:    ClaimLease.abandoned?(...) — every channel silent past the
  #                 idle window. Only consulted when a holder is identifiable.
  def decide(stage:, devops:, claim_live:, abandoned:)
    return :concluded if CONCLUDED_STAGES.include?(stage.to_s.strip)

    devops ||= {}
    return :held if claim_live
    return :unverifiable if unidentifiable?(devops)
    return :unheld unless identified?(devops)

    abandoned ? :abandoned : :working
  end

  # May the archive proceed on this grade?
  def permitted?(grade)
    PERMITTED.include?(grade)
  end

  # A holder we can go and check: some key names a session.
  def identified?(devops)
    IDENTITY_KEYS.any? { |key| present?((devops || {})[key]) }
  end

  # SOMEBODY was here, and we cannot tell who. The near-miss's shape: a mascot (or
  # an agent slug, or a builder list) with no session behind any of it.
  #
  # Ordered after `identified?` by its only caller, so a record carrying BOTH a
  # mascot and a session is checkable and never lands here.
  def unidentifiable?(devops)
    devops ||= {}
    !identified?(devops) && PAINT_KEYS.any? { |key| present?(devops[key]) }
  end

  # The holder signals a record DOES carry, for the refusal to name. Returns pairs
  # so the message can print the record as it actually stands — the operator's next
  # move is to go and find that session, and they can only do it with the paint we
  # actually have.
  def paint(devops)
    devops ||= {}
    PAINT_KEYS.filter_map do |key|
      value = devops[key]
      [key, render(value)] if present?(value)
    end
  end

  # `desk_touched` for ClaimLease.abandoned?, drawing the line this file exists to
  # draw: a desk that IS NOT THERE is a real, negative answer; a desk that is there
  # and cannot be read is an unknown that protects.
  #
  # `reader` is the seam the unit tier drives in place of a filesystem walk; it
  # receives the desk path and returns DeskActivity.touched_since?'s tri-state.
  def desk_touched_for(desk_dir, exists:, reader:)
    return false unless exists   # no desk → no uncommitted work in one → not touched
    return nil if desk_dir.to_s.strip.empty?

    reader.call(desk_dir)
  end

  # --- refusals ------------------------------------------------------------------
  #
  # Every refusal NAMES what it could not verify. A guard that blocks without
  # saying what it could not establish just moves the operator's confusion one step
  # later — and the acceptance criterion here is explicitly that the refusal names
  # it, because the near-miss was resolved by naming the holder out loud.

  def refusal(grade, slug:, stage:, devops:, claim: nil, channel: nil)
    case grade
    when :unverifiable then unverifiable_refusal(slug, stage, devops)
    when :held         then held_refusal(slug, claim)
    when :working      then working_refusal(slug, channel)
    end
  end

  def unverifiable_refusal(slug, stage, devops)
    held = paint(devops)
    carried =
      if held.empty?
        "     the record carries no holder signal we can resolve at all"
      else
        held.map { |key, value| "     #{key}: #{value}" }.join("\n")
      end

    <<~TEXT.rstrip
      ⚠  REFUSING to archive #{slug} — it is #{stage}, and its holder CANNOT BE IDENTIFIED.

         Something filed this task and left its paint on it, but nothing in the record
         names a SESSION, so there is nobody to ask whether they are still working:
      #{carried}
         missing: #{IDENTITY_KEYS.join(", ")} — every key a liveness check is keyed on.

         `archived` is terminal and the work it destroys is UNCOMMITTED: no gate, review,
         or CI would ever surface it. On 2026-09-01 a record in exactly this shape (an app
         and a mascot) was resolved only by messaging the peer session; had it been idle or
         unreachable, live work would have been archived.

         Identify the holder before archiving:
           bin/agent-presence                          # who is live on this machine right now
           bin/task show #{slug} --verbose
         Then, if you have established that nobody holds it, say so explicitly:
           bin/task move #{slug} archived --force
    TEXT
  end

  def held_refusal(slug, claim)
    claim ||= {}
    session = claim["claimed_session"].to_s
    age = ClaimLease.heartbeat_age(claim)
    heartbeat =
      if age.nil?
        "its lease expiry is PRESENT and UNPARSEABLE, so we could not check the heartbeat at all"
      else
        "last heartbeat ~#{age}s ago (lease TTL #{ClaimLease::DEFAULT_TTL_SECONDS}s)"
      end

    <<~TEXT.rstrip
      ⚠  REFUSING to archive #{slug} — a LIVE session holds it.

         session …#{session[-4..] || session}  instance #{claim["claim_nonce"]}
         #{heartbeat}

         Archiving it would destroy that session's uncommitted work. Ask the holder first
         (bin/agent-presence names who is live on this machine). To archive anyway:
           bin/task move #{slug} archived --force
    TEXT
  end

  def working_refusal(slug, channel)
    <<~TEXT.rstrip
      ⚠  REFUSING to archive #{slug} — it could not be shown abandoned.

         #{channel}

         A task we cannot prove abandoned is never archived. To archive anyway:
           bin/task move #{slug} archived --force
    TEXT
  end

  # Name the channel that kept the task, mirroring bin/agent-worktree's
  # desk_hold_reason: ClaimLease.abandoned? owns the DECISION, this renders it, so
  # the two can never disagree about whether to hold — at most about how to say it.
  # The trailing fallback is for exactly that residue: an honest "could not be shown
  # abandoned" rather than a confident lie about which channel spoke.
  def working_channel(channels)
    window = ClaimLease.humanize_age(ClaimLease::DESK_IDLE_SECONDS)
    touched = channels[:desk_touched]
    return "its desk could not be read, so we could not tell whether anyone is working in it" if touched.nil?
    return "its desk was written to within the last #{window} — somebody is working in it, and their " \
           "uncommitted work is exactly what archiving discards" if touched

    if channels[:gate_in_flight]
      cert_p99 = ClaimLease.humanize_age(ClaimLease::MEASURED_SILENCE_SECONDS[:cert_p99])
      return "a gate the holder opened is still running — a cert writes nothing into its desk for up " \
             "to #{cert_p99}, so a quiet desk mid-cert is a working one"
    end
    return "the task is waiting on the operator's approval, so its agent is right to be doing nothing" if channels[:awaiting_approval]

    progress = channels[:progress_age]
    if !progress.nil? && progress <= ClaimLease::DESK_IDLE_SECONDS
      return "the holder landed a durable artifact #{ClaimLease.humanize_age(progress)} ago, inside " \
             "the #{window} idle window"
    end

    "it could not be shown abandoned, and a task we cannot prove abandoned is never archived"
  end

  def present?(value)
    case value
    when nil            then false
    when Array          then value.any? { |entry| present?(entry) }
    when true           then true
    when false          then false
    else !value.to_s.strip.empty?
    end
  end

  def render(value)
    value.is_a?(Array) ? value.map(&:to_s).reject(&:empty?).join(", ") : value.to_s.strip
  end
end
