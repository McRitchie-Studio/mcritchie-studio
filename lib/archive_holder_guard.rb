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
#   ARCHIVE ONLY WHAT WE CAN PROVE HOLDS NO WORK AT RISK.
#
# "WORK AT RISK" is the load-bearing phrase, and it is narrower than "live". What an
# archive can destroy is UNCOMMITTED state, and uncommitted state lives in a DESK.
# Anything already durable — a commit, a PR, a board row, a TaskEvent — survives the
# archive untouched and can be read back afterwards, so it is not at risk and must
# not hold the gate. See the board-progress section below for the measured cost of
# getting that distinction wrong.
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
#
# ═══ WHY BOARD PROGRESS IS NOT A CHANNEL HERE ═══
#
# THE MEASUREMENT that put this section in the file. Graded against the live board
# on 2026-09-02 (34 tasks in designed/building/submitted/reviewed), the first cut of
# this gate REFUSED 31 — every one of them on `:working`, and every one held by
# `progress_age`, while `:unverifiable`, the case the whole file exists for, fired on
# ZERO. SIXTEEN of the 31 had `desk_touched == false`: no desk at all, or a desk
# provably quiet past the idle window. There was nothing uncommitted to protect, and
# the gate refused anyway.
#
# That is not a tuning miss, it is the wrong proposition. THREE REASONS, in order of
# how much they should worry you:
#
#   1. IT ANSWERS A DIFFERENT QUESTION. `progress_age` here is Task
#      #holder_liveness_seconds_ago — "seconds since the newest artifact not
#      DEMONSTRABLY someone else's". That predicate is defined relative to a holder.
#      Where there is no holder, nothing is demonstrably anyone else's, so it
#      degrades to the age of the task's own creation event. Measured on
#      `document-credential-slot-engine-floor` (`designed`, no desk): created
#      04:53:51.647Z, `last_progress_at` 04:53:51.650Z — THREE MILLISECONDS later,
#      labelled "moved to designed", `last_progress_actor` NULL. The gate read a
#      row nobody wrote, about work nobody had started, as somebody working.
#
#   2. IT IS A SIGNAL THIS VERB WRITES. Every `bin/task` write — a note, a block, a
#      stage move, an update — lands a TaskEvent and resets it, so triaging a task
#      arms the gate against archiving that same task for the next
#      DESK_IDLE_SECONDS. Six of the 16 came back reading 155-156s: one board sweep,
#      one instant, six tasks locked away from the archive at once. Steffon's
#      archive-shipped.md already documents this trap
#      for the reclaim gate ("⛔ Step 7 BLOCKS step 8 — the run under-reclaims by
#      design"; measured 2026-08-26, 7 desks previewed, 4 taken). The reclaim can
#      afford it — it is an idempotent sweep that re-runs after the window. The
#      archive is the TERMINAL act at the end of Alex's `clean-up`, whose earlier
#      phases triage the very tasks the last phase archives; there is no later run
#      to catch what the gate bounced.
#
#   3. IT COSTS THE GUARD ITS LIFE. `clean-up` archives exactly this population, so
#      under the first cut its first run was 31 `--force` invocations — after which
#      `--force` is muscle memory and the gate protects nothing. THIS FILE'S OWN
#      docblock names that outcome as fatal ("a guard that refuses everything is
#      uninstalled within a week"). Refusing everything and archiving everything are
#      the SAME failure wearing different clothes, and a gate has to survive both.
#
# So the archive path asks `abandonable?` (below) rather than ClaimLease.abandoned?
# directly: same predicate, same arithmetic, one notion of liveness — with the
# board-progress channel deliberately not supplied. The three channels that remain
# all attest work at risk: a desk being written into, a cert running against one, or
# an operator parked in front of one.
#
# RE-GRADED ON THE SAME 34 TASKS, the narrowing takes the refusals from 31 to 15, and
# the split is TOTAL rather than approximate — which is the result to re-check if you
# change any of this:
#   * all 16 that flipped to ARCHIVE had `desk_touched == false`. Not one of them had
#     a desk being worked in.
#   * all 15 that still REFUSE have `desk_touched == true`. Not one of them is held
#     by anything other than a live desk.
# The gate now refuses exactly where uncommitted work exists, and nowhere else.
#
# ═══ SCOPE: THIS GATE IS THE CLI PATH, DELIBERATELY ═══
#
# Task#archive!, the board's Archive buttons, and a raw API PATCH all bypass it.
# That asymmetry is intended, not an oversight. The gate exists to stop an AGENT
# archiving work it never looked at, and `bin/task` is the agent's hand; the board
# buttons are Mr. McRitchie's own, and a human clicking Archive on a task page they
# are reading IS the deliberate decision `--force` exists to represent. Putting the
# gate in the model would make the operator fight it from a UI with nowhere to show
# a refusal — and the failure this guard was built for was an agent's, not his.
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
  #
  # EVERY NAME HERE MUST BE A STORABLE devops KEY, or the refusal it is supposed to
  # trigger can never fire. `agent_slug` sat in this list for one review and was
  # dead the whole time: it is a top-level `tasks` COLUMN, so Task
  # .normalize_devops_metadata drops it (`next unless DEVOPS_KEYS.include?(key)`)
  # and `devops["agent_slug"]` is nil on all 1,575 tasks on the board. A key list
  # nobody can populate is a promise the gate cannot keep, so it is gone.
  #
  # The three that replaced it carry real paint and were graded `:unheld` — the
  # "nobody was ever here" verdict — while naming a worker out loud:
  #   builders               the AUTHOR SET bin/reviewer-select excludes (113 tasks)
  #   builders_unattributed  the model's own words: "a session worked this while
  #                          naming no soul" — which IS this file's definition of
  #                          :unverifiable, spelled by a different subsystem
  #   persona                the soul a session ran as
  PAINT_KEYS = %w[mascot built_by builders builders_unattributed persona].freeze

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
  #   abandoned:    `abandonable?` (below) — every channel that attests WORK AT RISK
  #                 silent past the idle window. NOT ClaimLease.abandoned? directly:
  #                 that one also weighs board progress, which this gate must not.
  #                 Only consulted when a holder is identifiable.
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

  # "Every channel that attests WORK AT RISK is silent" — the `abandoned:` fact
  # `decide` consumes, and the one place this file states which channels those are.
  #
  # It DELEGATES rather than reimplements. ClaimLease.abandoned? owns the fold (any
  # positive signal and any unknown keep the holder), so there is still exactly one
  # notion of "is the holder working" on this machine and no second one to drift
  # from it. What this wrapper adds is the SELECTION, and it is the whole fix: the
  # board-progress channel is not supplied, because a durable board artifact is not
  # work an archive can destroy. See "WHY BOARD PROGRESS IS NOT A CHANNEL HERE".
  #
  # `progress_age` is deliberately NOT a parameter. Accepting it and ignoring it
  # would let a future caller pass it in good faith and quietly get nothing; leaving
  # it out means Ruby raises `unknown keyword: :progress_age` at the call site, so
  # re-wiring the channel has to be a decision somebody makes on purpose.
  #
  # The omission is also arithmetic rather than taste. Read ClaimLease.abandoned?'s
  # short-circuits in order: nil desk, touched desk, gate, approval all return early,
  # so `progress_age` is only ever REACHED when the desk has already answered false —
  # already told us there is no uncommitted work in one. It could never do anything
  # but overturn that answer, which is precisely the 16 false refusals it produced.
  def abandonable?(desk_touched:, gate_in_flight: false, awaiting_approval: false)
    ClaimLease.abandoned?(
      desk_touched: desk_touched,
      gate_in_flight: gate_in_flight,
      awaiting_approval: awaiting_approval
    )
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
           bin/agent-worktree list                     # which desk carries this task, and whose
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
  # desk_hold_reason: `abandonable?` owns the DECISION, this renders it, so the two
  # can never disagree about whether to hold — at most about how to say it.
  #
  # THE BRANCHES HERE ARE THE CHANNELS THERE, one for one, and that correspondence
  # is the contract. A branch for a channel the decision no longer consults would
  # let the gate refuse for one reason and blame another; the board-progress branch
  # left with the channel for exactly that reason. The trailing fallback is the
  # honest residue — "could not be shown abandoned" rather than a confident lie
  # about which channel spoke. It is unreachable while the four branches above cover
  # the four early returns `abandonable?` can take (nil desk, touched desk, gate,
  # approval), and it stays because the next channel added will land there before
  # anyone remembers to write its sentence.
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
