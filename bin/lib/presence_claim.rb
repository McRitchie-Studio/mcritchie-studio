# frozen_string_literal: true

require "json"
require "time"
require_relative "session_markers"
require_relative "cert_orphan_guard"
require_relative "projects_root"

# PresenceClaim — the WRITER half of the agent-presence surface
# (docs/agents/system/agent-presence.md, slice 3). It publishes ONE claim per unit
# of heavy work, so a peer can ask "is it safe for me to start?" by READING rather
# than by inferring.
#
# ── WHY THIS EXISTS, measured on this box on 2026-09-01 ───────────────────────
#
# `bin/agent-presence` (the slice-1 reader) was pointed at a live machine and
# reported, verbatim:
#
#   cert claims (1 on disk, 1 live)
#     LIVE  mcritchie-studio/primary-refusal-names-waived-lane  pid 53432  3m
#   backstop: 6 heavy workload(s) carry NO claim — UNATTRIBUTED, not idle:
#     ship pgid 43603 (2 procs)  ruby …/bin/ship stale-engine-web3-comments …
#     ship pgid 60237 (2 procs)  ruby …/bin/ship runbook-names-dead-host …
#     ship pgid 62081 (2 procs)  ruby bin/ship backup-collisions-are-silent …
#     ship pgid 63580 (2 procs)  ruby bin/ship archive-refuses-unknown-holder …
#     ship pgid 75015 (3 procs)  ruby …/bin/ship restore-web3-modal-coverage …
#   verdict: BUSY
#
# Every one of those five groups measured 0.0% CPU. FOUR were parked in a CI wait,
# costing nothing; the fifth had just spawned `bin/fast-check` eleven seconds
# earlier and was about to cost a whole core-set for ten minutes. The reader could
# not tell them apart, so it called the machine BUSY on the strength of four idle
# waiters — and an agent reading that holds off for nothing. Invert it and the
# error is worse: an agent that discounts `bin/ship` launches straight into the
# fifth one's suite.
#
# That is cost #4 in the design, reproduced live. The process NAME is identical in
# both states; nothing in it ENCODES the distinction. So the process publishes the
# distinction itself.
#
# ── THE RULE THIS OBEYS ───────────────────────────────────────────────────────
#
#   No claim asserts its own liveness. Every claim carries the OS's proof of
#   identity, and the READER decides.
#
# `started_at` is `ps -o lstart=`'s rendering of the process start time, compared
# as an OPAQUE STRING and never as a parsed clock — CertOrphanGuard's rule,
# reused rather than re-invented. A pid is a recyclable integer, so liveness is
# not identity; the start time is what makes (pid, started_at) name a PROCESS
# instead of merely addressing a slot.
#
# WHAT HAPPENS WHEN THE WRITER IS KILLED — the question that decides whether this
# is safe to add at all. `#clear` runs on graceful exit and is an OPTIMIZATION
# ONLY. A SIGKILLed writer leaves its file behind, exactly as the cert runlock
# does, and that file's only claim to being live is a pid and a start time the OS
# contradicts on the very next read. There is no timeout to elapse and no renewal
# to miss, so THE WEDGE WINDOW IS ZERO rather than one TTL. This is precisely the
# constraint the original ticket set — "a stale cert-running file that never
# clears would be strictly worse than the grep it replaces" — and it is satisfied
# by construction, not by cleanup discipline.
#
# The one residual staleness is `phase`: a LIVE writer that died between
# boundaries leaves a phase that is out of date, so a peer over-estimates cost and
# waits. That is bounded by the writer's own lifetime and it lands on the latency
# side, which is the side every error mode here is arranged to land on.
#
# ── WHERE IT LIVES, AND WHY NOT A NEW DIRECTORY ───────────────────────────────
#
# `<projects>/.agents/sessions/<session-id>.presence-<kind>-<pid>`, inside the
# session-marker namespace on purpose. That namespace already has ONE owner
# (bin/lib/session_markers.rb), a sandbox choke point every mutation passes, a
# private path builder, and a containment test that re-derives the mutation set
# from source. A new store would have to re-earn all four. So this class holds no
# path: it builds a SUFFIX and a body, and SessionMarkers builds and guards the
# path. That is also why bin/ship can call it without appearing in the containment
# test's ALLOWED_CONSTRUCTORS — bin/ship never names the store.
class PresenceClaim
  SCHEMA_VERSION = 1

  # The phase vocabulary the reader already honors (bin/lib/agent_presence.rb):
  # WAITING consumes nothing and is weighed at zero whatever `weight` says.
  WORKING = "working"
  WAITING = "waiting"
  PHASES = [WORKING, WAITING].freeze

  # Weight classes, matching the reader's map. Explicitly a first cut — the design
  # records that a parallel Rails suite forks per core, so weight may eventually
  # need to be a number rather than a class.
  SUITE = "suite"
  LIGHT = "light"
  IDLE  = "idle"
  WEIGHTS = [SUITE, LIGHT, IDLE].freeze

  # A run with no agent session still publishes. The filename needs a namespace
  # key, not a session, and a claim that exists exactly when the process exists is
  # the whole point — a session-less `bin/ship` run by hand consumes the machine
  # identically. The BODY still reports `session_id: null`, so nothing is claimed
  # that is not known.
  def self.unbound_key(pid) = "unbound-#{pid}"

  # Open a claim for the current process. Reads the process table ONCE, here, for
  # both identity proofs: a process's start time cannot change, so re-reading it at
  # every phase boundary would spend a `ps` to learn the same fact.
  #
  # TWO SUBJECTS, for the reason CertOrphanGuard's runlock names two. The supervisor
  # can be killed while the work it spawned SURVIVES — reparented to launchd, still
  # burning the machine and still holding a test DB — and a claim naming only the
  # supervisor reports that worst case as `dead`, which is the one direction this
  # design may never fail in. `bin/ship` spawns bin/fast-check with `system` and no
  # `pgroup:`, so the child runs in the SHIP'S OWN group: the group is exactly the
  # right second subject, and it is what makes a SIGKILLed ship whose cert lives on
  # still grade live.
  #
  # Publishing a pgid here carries NO reaping hazard, and that is a property of WHERE
  # this claim lives rather than of luck. CertOrphanGuard.preflight REAPS — it SIGKILLs
  # the group a lock names — and it reads `<root>/.git/cert-run.json`, only ever that.
  # A claim in the session-marker namespace is invisible to it by construction, so the
  # reaper can never be pointed at a process no cert spawned. A non-cert claim written
  # into a desk's runlock SLOT would not have that property.
  #
  # `session_id` nil is a first-class state, not a failure — see `unbound_key`.
  def self.open(kind:, root:, projects_dir: nil, session_id: nil, task_slug: nil,
                pid: Process.pid, pgid: nil, env: ENV, ps: CertOrphanGuard.ps_bin, now: Time.now)
    pgid ||= begin
      Process.getpgid(pid)
    rescue SystemCallError
      nil
    end
    new(kind: kind, root: root, projects_dir: projects_dir || projects_dir_from(env), session_id: session_id,
        task_slug: task_slug, pid: pid, pgid: pgid, env: env,
        pid_started_at: CertOrphanGuard.process_started_at(pid, ps: ps),
        pgid_started_at: pgid && CertOrphanGuard.process_started_at(pgid, ps: ps), began_at: now)
  end

  # The session-marker store's OWN pin, resolved exactly as bin/lib/agent_api.rb
  # resolves it. CLAUDE_PROJECTS_DIR is what TaskUsageSandbox::STORES names for
  # "session-marker", so reading it HERE is what lets a sandboxed caller pin the
  # store it is about to write — a resolver that ignored the pin would be refused
  # by the guard on every test run, and would reach the operator's live store on
  # every real one. ProjectsRoot supplies only the DEFAULT (it climbs out of
  # .worktrees, so a desk shares the primary's .agents).
  def self.projects_dir_from(env)
    dir = env["CLAUDE_PROJECTS_DIR"].to_s.strip
    dir.empty? ? ProjectsRoot.default_projects_dir : File.expand_path(dir)
  end

  attr_reader :kind, :pid, :pgid, :pid_started_at, :pgid_started_at, :session_id, :task_slug,
              :root, :phase, :weight

  def initialize(kind:, root:, projects_dir:, session_id:, task_slug:, pid:, pgid:, env:,
                 pid_started_at:, pgid_started_at:, began_at:)
    @kind = sanitize(kind)
    @root = root.to_s
    @projects_dir = projects_dir.to_s
    @session_id = session_id.to_s.strip.empty? ? nil : session_id.to_s.strip
    @task_slug = task_slug
    @pid = pid.to_i
    @pgid = pgid&.to_i
    @env = env
    @pid_started_at = pid_started_at
    @pgid_started_at = pgid_started_at
    @began_at = began_at.utc.iso8601
    @phase = nil
    @weight = nil
    @lane = nil
  end

  # Publish (or re-publish) the claim at a phase boundary. Returns the marker path,
  # or nil when the write failed — best-effort, exactly like every other marker:
  # NOTHING here may take down the work it is describing. A sandbox violation is
  # not an IO failure and still aborts, which is the guarantee that keeps a test
  # run out of the operator's live store.
  def publish(phase:, weight:, lane: nil, now: Time.now)
    @phase = phase
    @weight = weight
    @lane = lane
    SessionMarkers.write(marker_key, @projects_dir, suffix, "#{JSON.generate(body(now))}\n", env: @env)
  end

  # Remove the claim. AN OPTIMIZATION ONLY — see the header. Correctness never
  # depends on this running.
  def clear
    SessionMarkers.delete(marker_key, @projects_dir, suffix, env: @env)
  end

  # The record. Every field is either a FACT ABOUT THIS PROCESS or a label; none of
  # them is an assertion of liveness, because that is the reader's to make.
  #
  # THE FIELD NAMES ARE THE RUNLOCK'S, and that is deliberate — it is where the
  # design's §4 and §5(c) disagreed and §5(c) wins. §4 sketched `started_at` as the
  # OS start time; §5(c) says these claims are read by "the same glob and the same
  # GRADER" as the runlock, and that grader reads `started_at` as the ISO stamp of
  # when the record was written and takes its identity from `<subject>_started_at`.
  # A record that spelled one field two ways would put two truths on one screen and
  # neither call site would look wrong. So:
  #
  #   started_at        ISO — when this record was written. Same meaning as the runlock's.
  #   pid  / pid_started_at    the SUPERVISOR subject (the runlock spells it cert_pid).
  #   pgid / pgid_started_at   the GROUP subject. Same spelling as the runlock's.
  #   began_at          ISO — when the RUN began; constant across every republish.
  #
  # The supervisor subject keeps an honest name rather than borrowing `cert_pid`: a
  # ship is not a cert, and the reader translates one pair of names at its boundary
  # instead of the record lying about what it holds.
  def body(now = Time.now)
    stamp = now.utc.iso8601
    {
      "schema_version" => SCHEMA_VERSION,
      "kind" => @kind,
      "phase" => @phase,
      "weight" => @weight,
      "lane" => @lane,
      "pid" => @pid,
      "pid_started_at" => @pid_started_at,
      "pgid" => @pgid,
      "pgid_started_at" => @pgid_started_at,
      "session_id" => @session_id,
      "agent" => acting_agent,
      "task_slug" => @task_slug,
      "repo" => repo,
      "root" => @root,
      "started_at" => stamp,
      "began_at" => @began_at,
      "phase_since" => stamp
    }
  end

  # Repo and desk from the ROOT PATH — no `git`, no registry lookup, matching how
  # the reader locates a runlock. A worktree lives at
  # <primary>/.worktrees/<desk>, so the repo is two levels up from there.
  def repo
    parent = File.basename(File.dirname(@root))
    parent == ".worktrees" ? File.basename(File.expand_path("../..", @root)) : File.basename(@root)
  end

  private

  # The session's soul, when it has published one. Best-effort and READ-ONLY: this
  # is the marker bin/atomic-event already keeps, so the row can say "carl" rather
  # than leaving a human to join it by hand. Absent is a normal answer.
  def acting_agent
    return nil unless @session_id

    value = SessionMarkers.read(@session_id, @projects_dir, ".acting-agent").to_s.strip
    value.empty? ? nil : value
  end

  def marker_key = @session_id || self.class.unbound_key(@pid)

  # ONE file per process, not per phase: the pid keys it, so a phase change
  # REWRITES the claim rather than leaving a trail of contradicting ones. Two
  # concurrent ships in the same session are two pids and two files, which is
  # correct — they are two workloads.
  def suffix = ".presence-#{@kind}-#{@pid}"

  # Defence in depth for a path segment. SessionMarkers sanitizes the session id
  # and nothing else, so the one component a caller chooses is sanitized here.
  def sanitize(value) = value.to_s.gsub(/[^A-Za-z0-9_-]/, "")
end
