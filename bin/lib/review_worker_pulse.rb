# frozen_string_literal: true

require_relative "../../lib/claim_lease"
require_relative "session_markers"

# ReviewWorkerPulse — the WORKER-level half of "is this review still being done",
# and the answer to a reviewer that dies inside a session that does not.
#
# ═══ WHY bin/lib/anchor_heartbeat.rb CANNOT REACH THIS ═══
#
# AnchorHeartbeat answers about the SESSION: resident process + narration inside
# PROGRESS_QUIET_SECONDS. It was built for two faces of one defect — no anchor at
# all (the claim lapses one TTL in), and a dead anchor still in the process table
# (it renews forever). THIS IS NEITHER. The anchor is genuinely alive and genuinely
# working, because the CONDUCTOR is alive and working; only the reviewer subagent
# died. Every signal AnchorHeartbeat reads is a TRUE POSITIVE about the session and
# says nothing whatever about the worker whose review the claim describes.
#
# So this file is strictly ADDITIONAL. It never loosens the session check, which is
# correct and load-bearing for the other two faces; it adds a fact the session check
# cannot carry.
#
# ═══ THE MEASUREMENT THAT DECIDED THE DESIGN, 2026-09-22 ═══
#
# The obvious fix — "record the SUBAGENT identity alongside the session, so liveness
# can ask about the worker" — was tried first and is NOT IMPLEMENTABLE. A subagent
# carries no identity of its own. Measured by running one probe from a parent agent
# and the same probe from a subagent of it, on the same machine, seconds apart:
#
#   CLAUDE_CODE_SESSION_ID   1c7e1097-…debe   ==   1c7e1097-…debe
#   CLAUDE_PID               30691            ==   30691
#   shell ppid               30691            ==   30691   (both: the `claude` process)
#   SessionIdentity.nonce    0e69fc8b45f5     ==   0e69fc8b45f5
#   SessionIdentity.agent_process  {pid: 30691, start: "Sun Sep 20 08:50:56 2026"}  (identical)
#
# Byte-identical on every identity-bearing variable. A subagent is not an OS process:
# its shell commands are direct children of the session's `claude` process and inherit
# that process's whole environment. There is no env var, no pid, no ancestry step, and
# no nonce that differs. THERE IS NOTHING TO RECORD — so a claim cannot be made to name
# its worker, and no amount of serializer work changes that.
#
# ═══ WHAT IS ACTUALLY MISSING, WHICH IS NOT AN IDENTITY ═══
#
# A review claim is touched in the FOREGROUND exactly ONCE in its entire life — the
# `acquire`. Every beat after that comes from the detached renew-loop, which is
# anchored to the session. So from the moment of acquisition the claim carries NO
# worker-produced evidence at all, and a live reviewer and a dead one are
# indistinguishable because THERE IS NOTHING TO DISTINGUISH THEM WITH. (Checked, not
# assumed: the review SOPs call `acquire`, `status` and `release`; `renew` exists and
# nothing in the review lane ran it by hand.)
#
# That is a missing SIGNAL, not a missing identity — and a signal can be created where
# an identity cannot. The pulse is the mtime of the per-(session, slug) claim marker
# `<projects>/.agents/sessions/<id>.task-review-claim-<slug>`, which ALREADY EXISTS and
# is ALREADY keyed to the one thing the worker is working on. A foreground review-claim
# command refreshes it; nothing else may.
#
# WHAT MAY TOUCH THE PULSE, and what deliberately may not:
#
#   IT MAY     — `acquire` / `claim-next` (the seed) and `renew` (the worker's own
#                beat). These run in the FOREGROUND, as a tool call, which is the one
#                thing a dead subagent cannot do.
#   IT MAY NOT — the detached `renew-loop`. NOTHING A RENEWER WRITES MAY COUNT AS ITS
#                OWN EVIDENCE; a lease certifying itself is indistinguishable from the
#                defect this file closes. The identical rule is stated in
#                bin/lib/anchor_heartbeat.rb's header, one granularity up.
#   IT MAY NOT — `status`. A DIAGNOSTIC MAY NOT MANUFACTURE THE EVIDENCE IT REPORTS.
#                A conductor checking on a suspected-dead reviewer would otherwise
#                refresh the very pulse it is about to read and be told the worker is
#                alive — every time, and most confidently in exactly the case the
#                reader is trying to diagnose.
#
# ═══ THE AGE IS THE DIAGNOSTIC; THE VERDICT IS THE BRAKE ═══
#
# These are separate on purpose, because they are wanted on different timescales.
#
# The conductor in the incident needed an answer in MINUTES — and the honest answer
# available in minutes is not a verdict but the AGE itself: "nothing in this session
# has acted on this review for 38m; only the detached renewer is keeping it alive."
# That sentence is TRUE the moment it is printed and it names the one party who can
# resolve it. A verdict on that timescale would be a guess.
#
# The VERDICT — the thing that stops a renewal — keeps the conservative bound below,
# because stopping a renewal on a live review is the expensive direction.
#
# EVERY UNCERTAINTY KEEPS THE CLAIM, the same posture AnchorHeartbeat takes and for
# the same reason: this file can only ever STOP a renewal, so its failure mode is
# dropping a live reviewer's lease. A missing marker, an unreadable store, a blank
# session, a raised exception — all answer :unverified, which HOLDS.
#
# THAT ALSO SELF-LIMITS THE SCOPE, usefully. The marker is written by the instance
# that acquired the claim, so it exists only for a claim THIS machine's session holds.
# Asked about ANOTHER session's claim there is no marker, the answer is :unverified,
# and this file says nothing — so it can never free a lease belonging to a session it
# cannot observe. The narrower answer is the sound one.
#
# Pure and injectable — `verdict` reads no clock, no disk and no process table, so the
# decision is tested as arithmetic. The IO methods are thin and rescued.
module ReviewWorkerPulse
  # HOW LONG A REVIEW MAY GO WITHOUT A FOREGROUND TOUCH BEFORE THE CLAIM STOPS.
  #
  # DERIVED, NOT CHOSEN, and deliberately not a new number.
  # ClaimLease::REVIEW_TTL_SECONDS is the longest CONTINUOUS review ever measured,
  # cleared by half again, agreed by two independent instruments (1233 review windows;
  # 259 g2a_primary lane runs). A worker silent for longer than the longest review ever
  # observed has outlasted every live review in the corpus.
  #
  # It is the SAME constant ReviewClaimCli::REVIEW_RENEW_WINDOW_SECONDS already bounds
  # this lane with, and that is the point: the renewer's existing cap is a TIMEOUT
  # measured from the renewer's own start, so it frees a dead reviewer's task at 3h25m
  # whether the reviewer died in minute one or minute two hundred, and a LIVE reviewer
  # can do nothing about it. The pulse is the same bound made MOVABLE — a live worker
  # that beats pushes it forward, a dead one cannot. Same cost in the false-positive
  # direction, strictly more evidence behind it.
  SILENT_AFTER_SECONDS = ClaimLease::REVIEW_TTL_SECONDS

  # The suffix base of the per-(session, slug) claim marker whose mtime IS the pulse.
  # It is the marker ReviewClaimCli already writes at acquire and deletes at release;
  # this file adds a meaning to its mtime, not a second file to keep in step.
  MARKER = ".task-review-claim"

  # HOW MUCH NEWER THAN THE ACQUISITION A PULSE MUST BE TO COUNT AS A BEAT.
  #
  # `acquire` writes the marker inside the same command that takes the claim, so the
  # pulse and `acquired_at` describe one moment. They are nonetheless read from TWO
  # CLOCKS — `acquired_at` is the BOARD's, the pulse is this machine's file mtime — so
  # they will not agree exactly, and a bare `pulse > acquired` would call ordinary skew
  # a heartbeat. One renewal cadence is the smallest interval this lane already treats
  # as meaningful, and a real beat is separated from its acquire by the work in
  # between, which is minutes at least.
  BEAT_TOLERANCE_SECONDS = 30

  # The verdicts. Exactly one of them stops a renewal.
  #
  #   :active     — a foreground command acted on this review AFTER it was claimed.
  #                 A real beat: a tool call a dead subagent could not have made.
  #   :claimed_only — the ONLY foreground touch is the acquisition itself. Nothing has
  #                 happened in the foreground since. HOLDS — a review claimed two
  #                 minutes ago has legitimately had no beat yet — but it must SAY so,
  #                 because "active" here would assert a heartbeat that never happened.
  #                 This is the reading the live 2026-09-22 claim actually produced.
  #   :unverified — nothing can vouch either way (no marker, unreadable store, blank
  #                 session, another machine's claim). HOLDS: no evidence is not
  #                 evidence, and this file never frees a lease on silence it cannot
  #                 attribute.
  #   :silent     — the claim is being kept alive with no foreground touch for longer
  #                 than the longest review ever measured. STOPS renewing.
  STOPS_RENEWING = %i[silent].freeze

  module_function

  # The whole decision, as arithmetic.
  #
  # +pulse_age+ — seconds since a foreground command last acted on this review, or nil
  #               for UNKNOWN. nil and a number are different answers and must stay
  #               different: folding nil to a large number would turn "we could not
  #               look" into "nobody has touched it in ages", which frees leases on no
  #               evidence at all.
  # +acquired_age+ — seconds since the claim was taken, or nil when the board did not
  #                  say. nil means we cannot separate a beat from the acquisition, so
  #                  the answer degrades to :active, which HOLDS. Never to
  #                  :claimed_only: asserting "nothing has touched this" on a fact we
  #                  could not read would be the confident-wrong direction.
  def verdict(pulse_age:, acquired_age: nil, silent_after: SILENT_AFTER_SECONDS,
              beat_tolerance: BEAT_TOLERANCE_SECONDS)
    return :unverified if pulse_age.nil?
    return :silent if pulse_age > silent_after
    return :active if acquired_age.nil?
    return :claimed_only unless acquired_age - pulse_age > beat_tolerance

    :active
  end

  # Only :silent stops a renewal.
  def holding?(verdict) = !STOPS_RENEWING.include?(verdict)

  # The per-(session, slug) marker suffix. Slugs are kebab-case (validated on the
  # board), so already filesystem-safe; sanitize defensively anyway. Kept here rather
  # than reached for on the CLI so the writer and the reader of this marker's mtime
  # derive the same name from one place.
  def marker_suffix(slug)
    "#{MARKER}-#{slug.to_s.gsub(/[^A-Za-z0-9._-]/, '')}"
  end

  # Refresh the pulse — a FOREGROUND command acted on this review. Re-writes the
  # marker through SessionMarkers' guarded choke point rather than stamping the file
  # directly, because a raw marker path may not leave that module (see its header).
  # Best-effort: a claim is never lost because its pulse could not be written.
  def touch(session:, projects_dir:, slug:, env: ENV, markers: SessionMarkers)
    return nil if session.to_s.strip.empty?

    markers.write(session, projects_dir, marker_suffix(slug), "#{slug}\n", env: env)
  rescue StandardError
    nil
  end

  # Seconds since a foreground command last acted on this review, or nil when nothing
  # can vouch. Thin by design: SessionMarkers owns the path, this owns the arithmetic
  # and the rescue.
  def pulse_age(session:, projects_dir:, slug:, now: Time.now, markers: SessionMarkers)
    return nil if session.to_s.strip.empty?

    touched = markers.touched_at(session, projects_dir, marker_suffix(slug))
    return nil if touched.nil?

    age = now - touched
    age.negative? ? 0 : age
  rescue StandardError
    nil
  end

  # Is the claim's holder THIS session?
  #
  # The fact `status` already had in hand and threw away. GET
  # /api/v1/tasks/<slug>/review_claim returns the holder's `session`, and the CLI knows
  # its own — it simply never compared them, so it printed "ASK THE HOLDER TO RELEASE
  # IT (only their session can)" to a reader who WAS the holder. In the 2026-09-22
  # incident that sentence was the whole cost: the one party able to act was told to go
  # and ask somebody else.
  def mine?(holder_session:, session:)
    a = holder_session.to_s.strip
    b = session.to_s.strip
    return false if a.empty? || b.empty?

    a == b
  end

  # The line `status` prints about the worker, for a claim this session holds.
  #
  # It leads with the AGE rather than a verdict, and names the renewer explicitly,
  # because the reader's actual question is "is my reviewer still there" and the honest
  # answer is "nothing here can tell you — but here is exactly what is keeping this
  # claim alive, and you are the only one who can say whether that is a reviewer."
  def render(verdict, pulse_age, now_unknown: "never")
    age = pulse_age.nil? ? now_unknown : ClaimLease.humanize_age(pulse_age)

    case verdict
    when :active
      "worker: ACTIVE — a foreground command in this session acted on this review #{age} ago, " \
        "after it was claimed. A dead subagent cannot make a tool call."
    when :claimed_only
      "worker: NO BEAT — nothing has touched this review in the foreground since it was " \
        "CLAIMED #{age} ago; only the detached renewer, anchored to this session, is keeping " \
        "the claim alive. A live reviewer that has not beaten and a dead one read the same here."
    when :silent
      "worker: SILENT — no foreground command in this session has acted on this review " \
        "for #{age}, which is longer than the longest review ever measured. Only the " \
        "detached renewer, anchored to this session, is keeping the claim alive."
    else
      "worker: UNVERIFIED — this session has no local record of acting on this review, " \
        "so nothing here can vouch either way. The claim stands."
    end
  end

  # The next move for a claim held by THIS session — the sentence that replaces
  # "ASK THE HOLDER TO RELEASE IT (only their session can)" when the asking session IS
  # the holder.
  #
  # A live reviewer and a dead one are indistinguishable from here BY CONSTRUCTION (a
  # subagent has no identity to ask about; see this file's header), so this must not
  # pretend to a verdict. It states what is keeping the claim alive and hands the
  # question to the ONLY party that can answer it — the session that would know whether
  # it still has a reviewer working this task.
  def next_move_for_self(slug, verdict)
    lead = verdict == :active ? "THIS CLAIM IS YOURS" : "THIS CLAIM IS YOURS, AND NOTHING HERE PROVES A REVIEWER IS BEHIND IT"

    "→ #{lead} — the holder is THIS session, so there is nobody else to ask. A live " \
      "reviewer and a dead one read the same from here: a subagent shares its session's " \
      "id, nonce and anchor, so the renewer cannot tell them apart. You can. If your " \
      "reviewer for #{slug} is gone, release it: bin/task review-claim release #{slug}. " \
      "If it is still working, leave it alone."
  end

  # The `alive:` companion for the renew-loop: STOP only on a positive :silent reading.
  # Rescues everything to HOLDING, because an exception here would drop a live
  # reviewer's lease — strictly worse than the defect being fixed.
  #
  # +pulse+ is a callable returning the pulse age (or nil) so the lane's IO stays
  # injectable and this stays testable without a marker store.
  def alive_check(pulse:, silent_after: SILENT_AFTER_SECONDS)
    lambda do
      holding?(verdict(pulse_age: pulse.call, silent_after: silent_after))
    rescue StandardError
      true
    end
  end
end
