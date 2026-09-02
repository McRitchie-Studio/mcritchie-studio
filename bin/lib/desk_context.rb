# frozen_string_literal: true

require "json"
require_relative "cert_orphan_guard"

# DeskContext — the SESSION half of the desk context marker, and the reverse
# lookup it makes possible: *which live session holds task X, and what is it
# doing?*
#
# THE DEFECT THIS CLOSES IS A BROKEN JOIN, NOT A MISSING WRITE.
#
# The task that produced this file was framed as a reliability problem —
# "session→task binding happens 47% of the time, make it always happen". The
# evidence says otherwise, and the design follows from the difference. Proven by
# SET EQUALITY rather than by sampling: 375 session records lack a `task_slug`,
# and exactly 375 have a key set that is a subset of what the SessionStart mascot
# writer emits. 375 == 375 — not one record is a partial or aborted write. Half
# of all sessions GENUINELY hold no task: orchestrators, review sessions,
# questions, aborted starts. A backfill would have converted honest silence into
# a confident lie, which is the one outcome this whole surface exists to prevent.
#
# The real defect is structural. Two files each hold one half of the answer and
# neither carries the other's key:
#
#   .agents/sessions/<id>.json   knows the session (it is keyed by one) and STOPS
#                                recording the task the moment the session moves
#                                to a desk — `write_feature_marker` returns early
#                                whenever Dir.pwd is under "/.worktrees/".
#   <desk>/.agent-context.json   knows the task, and is refreshed on new / up /
#                                status / bind-task — but had NO session field at
#                                all. Verified across every desk on this machine.
#
# So for precisely the sessions doing the most work — the ones at a desk — the
# session record's stage freezes at its last pre-desk value and the desk holding
# the live truth cannot say whose it is. That is what cost an operator a held
# session that could only be identified by messaging peers one at a time.
#
# THE TWO EARLY RETURNS ARE ONE RULE, READ FROM BOTH ENDS. bin/task's guard is
# not a bug to be undone: a session at a desk should not write the global feature
# marker, because the desk's own marker is the authority there. This file
# supplies the other half of that same rule — the desk marker records the session
# WHEN THE SESSION IS ACTUALLY AT THE DESK. Together they say one thing: whoever
# is at the desk speaks for the desk.
#
# WHICH IS ALSO WHY A REFRESH FROM OUTSIDE MUST NOT STAMP. `status`, `whereami`
# and `bind-task` all take an explicit <app> <task-slug> and can be run from
# anywhere — the primary, or another agent's desk. A conductor sweeping every
# desk would then write ITS OWN session id onto all of them, and every one of
# those rows would grade `live`, because the conductor is alive. That is not a
# missing answer, it is a WRONG one delivered with full confidence — strictly
# worse than the silence it replaced. `claiming?` is the predicate that refuses
# it, and `stamp` preserves what is already on disk in every case where it says
# no.
module DeskContext
  # The marker file each desk carries, written by bin/agent-worktree.
  CONTEXT_FILE = ".agent-context.json"

  # 1 = the marker before the session join; 2 = with SESSION_FIELDS.
  #
  # The reader NEEDS this distinction and cannot derive it from the fields alone.
  # A marker with no `session_id` means one of two completely different things: the
  # writer predated the join and no answer was ever recorded, or a session-aware
  # writer looked and found nobody at the desk. Collapsing them would report honest
  # silence as a missing holder — the same lie a backfill would have told, moved one
  # layer up into the reader. Every desk on disk reads 1 until its next refresh,
  # which is the accurate thing for it to say.
  SCHEMA_VERSION = 2
  SESSION_AWARE_SCHEMA = 2

  # The session fields this module owns inside that marker. Everything else in
  # the payload belongs to bin/agent-worktree; these five are the join.
  #
  #   session_id         who is at the desk
  #   session_provider   claude | codex — a resume command differs by runtime
  #   parent_session_id  the fan-out root, when there is one, so five subagent
  #                      "sessions" read as ONE operator rather than five
  #                      independent claimants
  #   anchor_pid         the long-lived claude/codex process HOSTING the session
  #   anchor_started_at  its `ps -o lstart=` string — what makes the pid PROOF
  #
  # The anchor is two fields and not one on purpose. A bare pid is reused after
  # the process exits, so "the pid is alive" is a false positive for a holder
  # that died an hour ago. Recording the start time alongside it is what makes
  # this join GRADEABLE rather than merely present.
  #
  # THE ANCHOR IS PER-PROCESS, NOT PER-SESSION — measured 2026-09-01, and it is
  # the one thing a reader must not get wrong about this field. ONE `claude` CLI
  # process hosts MANY concurrent agent sessions: on this machine, pid 60790 was
  # the anchor for four sessions at once (three of them mid-`bin/ship` on
  # unrelated tasks), out of eight distinct CLI processes running. So the anchor
  # is one-to-MANY with sessions, and two consequences follow:
  #
  #   SOUND — a DEAD anchor proves the session is gone. Its host is gone, so it
  #           is gone. That is the direction the corpse grade depends on.
  #   WEAK  — a LIVE anchor proves only that the session's HOST is alive. The
  #           session itself may have ended while a sibling keeps the process up.
  #           `live` therefore means "may still be there", and that is the safe
  #           direction: over-reporting costs a message to a peer, under-reporting
  #           costs somebody's live work.
  #
  # DO NOT ATTRIBUTE MACHINE LOAD THROUGH THIS FIELD. Walking a heavy process's
  # ancestry to an anchor and joining on it looks like it names the session
  # burning the CPU, and it does not — every sibling session in the same CLI
  # process resolves to whichever desk happens to record that anchor. Measured
  # directly: a probe attributed three foreign `bin/ship` runs to this desk with
  # full confidence. `session_id` is the only unique key here, and nothing on
  # disk currently maps a heavy pid to one.
  SESSION_FIELDS = %w[session_id session_provider parent_session_id anchor_pid anchor_started_at].freeze

  # Grades that mean the holder is still there. Deliberately identical to
  # AgentPresence::COUNTED_GRADES — a reader that graded desks by one vocabulary
  # and cert runlocks by another would put two truths on one screen.
  COUNTED_GRADES = %i[live unverifiable].freeze

  module_function

  # --- the write decision (PURE) ---------------------------------------------------

  # Is THIS invocation entitled to stamp its session onto +dir+'s marker?
  #
  # True when the caller is working inside the desk (any depth — bin/ commands
  # run from subdirectories), or when +creating+ says the desk is being brought
  # into existence by this very call. `new` is the one moment where the caller is
  # unambiguously taking the desk: it did not exist a moment ago, so nobody else
  # can be at it.
  #
  # Everything else is an INSPECTION, not an occupancy, and must leave the
  # existing claim alone.
  def claiming?(dir, pwd: Dir.pwd, creating: false)
    return true if creating

    dir = dir.to_s
    return false if dir.empty?

    inside?(dir, pwd)
  end

  # Path containment by SEGMENT, never by prefix. "/w/desk-two" starts with
  # "/w/desk" as a string, and a desk whose slug is another desk's prefix is the
  # ordinary case here (`agent-presence` / `agent-presence-reader` are both live
  # on this machine right now). A prefix test would let the shorter desk claim
  # the longer one's marker.
  def inside?(dir, pwd)
    base = File.expand_path(dir.to_s)
    here = File.expand_path(pwd.to_s)
    return true if base == here

    here.start_with?("#{base}#{File::SEPARATOR}")
  end

  # The session fields to write into the marker, given what is already on disk.
  #
  # +existing+  the marker's current contents (nil for a fresh desk)
  # +session+   [id, provider] as SessionIdentity.identity returns it
  # +anchor+    { pid:, start: } as SessionIdentity.agent_process returns it, or nil
  # +parent+    the fan-out root session id, or nil
  # +claiming+  the verdict from `claiming?`
  #
  # PRESERVE IS THE DEFAULT, and there are exactly two roads to it:
  #   1. not claiming    — a peer is inspecting this desk; the occupant's claim stands
  #   2. no session id   — a plain shell or CI run; it is nobody, and nobody must
  #                        not erase somebody
  #
  # A MISSING ANCHOR IS NOT ONE OF THEM. When the session names itself but we cannot
  # find the long-lived process behind it, the claim is still WRITTEN — just without
  # the two anchor fields. Preserving instead would leave the previous occupant's
  # name on a desk this session has actually taken, which is the worse error; the
  # reader grades an anchor-less claim `unverifiable` and says so out loud, which is
  # the honest report.
  #
  # Returns only the keys it means to change, so the caller merges rather than
  # replaces. A whole-hash write here would drop app_color, mascot and every other
  # field the marker carries.
  def stamp(existing:, session:, anchor: nil, parent: nil, claiming: true)
    carried = carry_forward(existing)
    return carried unless claiming

    id, provider = session
    id = id.to_s.strip
    return carried if id.empty?

    fields = { "session_id" => id, "session_provider" => compact(provider) }
    fields["parent_session_id"] = compact(parent)
    fields["anchor_pid"] = anchor && anchor[:pid]
    fields["anchor_started_at"] = anchor && compact(anchor[:start])
    fields
  end

  # What a non-claiming refresh must hand back unchanged. Reads only the fields
  # this module owns — a marker rewritten by an inspecting peer keeps the
  # occupant's session exactly as the occupant left it.
  def carry_forward(existing)
    return {} unless existing.is_a?(Hash)

    SESSION_FIELDS.each_with_object({}) do |key, out|
      out[key] = existing[key] if existing.key?(key)
    end
  end

  def compact(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end

  # --- reading the desks -----------------------------------------------------------

  # Every desk marker under the projects root, in BOTH layouts the ecosystem uses:
  # the managed `<repo>/.worktrees/<slug>` and the sibling `<repo>.worktrees/<slug>`
  # tree the gem repos (studio-engine, solana-studio) live in. A glob that knew only
  # the managed layout would report the gem desks as "no holder" — the same
  # confident-wrong answer this file exists to refuse, one directory over.
  def context_paths(root)
    base = root.to_s
    return [] if base.empty?

    [
      File.join(base, "*", ".worktrees", "*", CONTEXT_FILE),
      File.join(base, "*.worktrees", "*", CONTEXT_FILE)
    ].flat_map { |pattern| Dir.glob(pattern) }.sort
  end

  # nil               — the file vanished between the glob and the read. A race,
  #                     not a defect: it is simply not a desk any more.
  # [:malformed, nil] — it is there and it is not a marker.
  # [:ok, hash]       — a marker. Whether anyone is AT it is not this method's call.
  def read_context(path)
    parsed = JSON.parse(File.read(path))
    return [:malformed, nil] unless parsed.is_a?(Hash) && !parsed.empty?

    [:ok, parsed]
  rescue JSON::ParserError
    [:malformed, nil]
  rescue Errno::ENOENT
    nil
  rescue SystemCallError
    [:malformed, nil]
  end

  # --- the grader ------------------------------------------------------------------

  # Grade one desk claim against a SNAPSHOT of the process table. Reads no clock,
  # no process table and no disk, so every vector is testable without spawning
  # anything.
  #
  #   :live         — the anchor is alive AND its start time matches EXACTLY. Read
  #                   it as "the holder MAY still be there": the anchor is the CLI
  #                   process hosting the session, and one process hosts several
  #                   (see SESSION_FIELDS). It is never wrong in the dangerous
  #                   direction — a live anchor can outlast its session, but a dead
  #                   one never survives it.
  #   :unverifiable — the anchor is alive and we cannot prove whose it is (no start
  #                   time recorded). NAMED, never silently trusted or discarded.
  #   :recycled     — something is alive at that pid and it is PROVABLY NOT ours.
  #                   The pid was reused. This desk's holder is gone.
  #   :dead         — nothing is alive at that pid. A corpse, graded on the very
  #                   next read with no timeout to wait out.
  #   :unclaimed    — the marker names no session at all. NOT a fault and NOT a
  #                   corpse: it is a desk nobody has sat down at since the fields
  #                   existed. The distinction is the entire point of the
  #                   diagnosis — an honest "no holder recorded" must never be
  #                   rendered as a dead one, or the surface re-tells the lie a
  #                   backfill would have told.
  #
  # Precedence follows AgentPresence: proof of life beats inability to prove,
  # which beats proof of innocence. Every tie breaks toward reporting a holder,
  # because over-reporting costs a message to a peer and under-reporting costs
  # somebody's live work.
  def grade(context:, table:)
    session = compact(context["session_id"])
    pid = CertOrphanGuard.coerce_pid(context["anchor_pid"])
    recorded = compact(context["anchor_started_at"])

    schema = context["schema_version"].to_i
    detail = {
      session_id: session, session_provider: compact(context["session_provider"]),
      parent_session_id: compact(context["parent_session_id"]),
      anchor_pid: pid, anchor_started_at: recorded,
      schema_version: schema,
      # "nobody is here" vs "this marker could never have said". The row renders
      # differently for each, and the second one has a remedy: refresh the desk.
      stale_schema: schema < SESSION_AWARE_SCHEMA
    }

    return [:unclaimed, detail] if session.nil?
    # A session id with no anchor is a claim we cannot grade. It is still a claim.
    return [:unverifiable, detail] if pid.nil?

    process = CertOrphanGuard.live_process(table, pid)
    detail = detail.merge(found: process)

    case CertOrphanGuard.identity_of(process, recorded)
    when :ours then [:live, detail]
    when :not_ours then [:recycled, detail]
    else process.nil? ? [:dead, detail] : [:unverifiable, detail]
    end
  end

  # --- the join --------------------------------------------------------------------

  # Every desk, graded. One `ps` snapshot for all of them, so the whole page
  # describes a consistent world rather than a world that moved while we read it.
  def desks(root:, table:)
    context_paths(root).filter_map do |path|
      status, context = read_context(path)
      next if status.nil?

      if status == :malformed
        next { path: path, desk: desk_name(path), grade: :malformed, task_slug: nil, detail: {} }
      end

      verdict, detail = grade(context: context, table: table)
      {
        path: path,
        desk: desk_name(path),
        repo: compact(context["app"]),
        grade: verdict,
        task_slug: compact(context["task_record_slug"]) || compact(context["task_slug"]),
        worktree: compact(context["worktree"]),
        branch: compact(context["branch"]),
        local_url: compact(context["local_url"]),
        stage: compact(context["stage"]),
        generated_at: compact(context["generated_at"]),
        detail: detail
      }
    end
  end

  # The desk's own name, from its path. No registry lookup and no `git`.
  def desk_name(path)
    File.basename(File.dirname(path.to_s))
  end

  # REVERSE LOOKUP — which desks hold this task. This is the question an agent
  # asks when a task blocks its ship: the board names a holding session id, and
  # until now nothing on disk could say what that session was DOING.
  def holders_of(task_slug, desks:)
    wanted = compact(task_slug)
    return [] if wanted.nil?

    desks.select { |d| d[:task_slug] == wanted }
  end

  # FORWARD LOOKUP — what is this session doing? Answered as a SET, because an
  # orchestrator legitimately holds several desks at once and a rule demanding
  # exactly one would recreate the lie a backfill would have told.
  def desks_of_session(session_id, desks:)
    wanted = compact(session_id)
    return [] if wanted.nil?

    desks.select do |d|
      d[:detail][:session_id] == wanted || d[:detail][:parent_session_id] == wanted
    end
  end

  # Does this grade mean somebody is still there?
  def live?(grade)
    COUNTED_GRADES.include?(grade)
  end
end
