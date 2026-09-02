# frozen_string_literal: true

require "json"
require "time"
require_relative "cert_orphan_guard"

# ReleasePresence — a sweep/ship publishes, LOCALLY, that it is consuming this machine.
#
# Slice 4 of docs/agents/system/agent-presence.md (jasper, 2026-09-01). It closes the
# design's MEASURED cost #3: a 45-minute full-suite run SIGTERMed at its 2700s ceiling
# having completed 11% of its tests, saturated by a `bin/release prepare` sweep that no
# status command reported.
#
# ------------------------------------------------------------------------------------
# THE DISTINCTION THIS EXISTS TO DRAW — a sweep was never "unclaimed"
# ------------------------------------------------------------------------------------
# `bin/release` already publishes itself TWICE, and neither publication answers the
# question a peer actually asks:
#
#   1. A board-side release conductor claim in the `assembler` role. It answers "IS A
#      RELEASE LIVE" — remotely, across machines, on a TTL. `bin/release-claim any-live
#      --role assembler` reads it, and in the whole ecosystem exactly ONE caller has ever
#      asked (the ship/gate workspace reclaim guard).
#   2. flocks under `<projects>/.agents/locks`. Those are invisible to anything that is
#      not ITSELF contending for the same lock — a peer about to launch a suite never
#      touches them, so it never learns anything.
#
# So a sweep publishes THAT A RELEASE IS LIVE, REMOTELY. It never publishes THAT THIS
# MACHINE IS SATURATED, LOCALLY. Those are different questions, and only the second one
# decides whether a peer may launch a suite. This module answers the second.
#
# ------------------------------------------------------------------------------------
# THE GOVERNING RULE — inherited whole from bin/lib/cert_orphan_guard.rb
# ------------------------------------------------------------------------------------
# NO CLAIM ASSERTS ITS OWN LIVENESS. The claim carries the OS's `(pid, lstart)` identity
# proof and THE READER DECIDES. That is why this is not a heartbeat and not a sixth TTL
# lease: the house already owns five, and they have failed in both directions — a shift
# lease renewed by a UI PAINT reported a lane FREE while its holder worked, and renewers
# that outlived their work spent the account-wide 1Password cap for a day. A TTL answers
# "did someone check in recently", which is a proxy. The process table answers the real
# question, for free, with no timeout to tune and no renewer to leak.
#
# KILLED-WRITER RULE. `close!` clears the claim on graceful exit as an OPTIMIZATION
# ONLY. Correctness comes from the reader grading identity against the process table: a
# SIGKILLed sweep leaves its file behind — by design, exactly as the cert runlock does —
# and it is graded a corpse on the very next read, with no timeout to elapse and no
# renewal to miss. THE WEDGE WINDOW IS ZERO, not one TTL.
#
# ------------------------------------------------------------------------------------
# WHY THE CLAIM IS A RUNLOCK, IN THE RUNLOCK'S OWN SLOT
# ------------------------------------------------------------------------------------
# The design's §4 sketches `.agents/sessions/<id>.presence-<kind>-<pid>`. This slice
# publishes to `CertOrphanGuard.lock_path(root)` instead, and the divergence is
# deliberate and load-bearing — §5(c) of the same document specifies that sweeps are read
# by "THE SAME GLOB AND THE SAME GRADER as (b)", and (b)'s glob is the runlock's:
#
#     */.git/cert-run.json   and   */.git/worktrees/*/cert-run.json
#
# A claim written anywhere else is invisible to the slice-1 reader (bin/agent-presence),
# which would leave the sweep sitting in the reader's `backstop` as UNATTRIBUTED heavy
# work — i.e. would not close cost #3 at all. Writing here means the reader needs NO
# change on its side, which is also why this module hand-builds nothing: it calls
# `CertOrphanGuard.write_lock`, the module that OWNS that file, so there is one atomic
# writer (tmp + rename; a plain `File.write` was measured returning nil on 4.6% of reads
# taken during its zero-byte window) and one identity format.
#
# WHY THE PRIMARY CHECKOUT. `claim_root` normalizes any desk path to its primary
# checkout, so a claim can never land in the slot a CERT's runlock occupies. That
# matters because `CertOrphanGuard.preflight` REAPS — it SIGKILLs a process group a
# runlock names once it can prove the group is ours — so a sweep claim sitting in a
# desk's runlock slot would be a sweep-killing landmine.
#
# A PRIMARY CHECKOUT IS NOT UNREACHABLE, AND THIS FILE USED TO CLAIM IT WAS. The earlier
# version of this header argued no cert ever preflights a primary, because
# `CertRootGuard.refusal` rejects a cert whose root is not the task's tree. That proof is
# FALSE, and it was stated as fact (review, 2026-09-02). The refusal is GATED —
# `if slug && ENV["FAST_CHECK_ROOT"].to_s.strip.empty?` (bin/fast-check:180,
# bin/full-suite-check:204) — while `CertOrphanGuard.preflight` is UNCONDITIONAL
# (bin/fast-check:372, bin/full-suite-check:448). So every slug-less cert skips the root
# guard and still preflights. The sharpest path is this repo's own opt-in hook:
# `--install-hook` writes `exec bin/full-suite-check --print` into `.git/hooks/pre-push`
# (bin/full-suite-check:170) with NO slug, so a plain `git push` from the primary reads
# this claim. `FAST_CHECK_ROOT`/`FULL_SUITE_ROOT` and a primary standing on `feat/<slug>`
# (cert_root_guard.rb:141) reach it too.
#
# SO SAFETY IS NOT LOCATION, IT IS WHAT THE CLAIM NAMES. A cert reading this file is
# expected and fine, because `open!` records `pgid` as the writer's OWN pid: once the
# conductor is dead, `decide` finds nothing alive at either subject and returns `:stale`
# — it clears the file and proceeds. It can never reach `:orphan` against a group this
# process did not own, which is the bystander-reaping bug that made the inherited-group
# record unsafe. See the long note in `open!`.
#
# ONE FILE PER ROOT, so `open!` REFUSES rather than clobbers. Two conductors are a
# documented occurrence here (a `prepare` and a `ship` may legitimately run at once), and
# both root at the same primary. Overwriting the incumbent would destroy a live peer's
# only local record — the same reasoning that makes CertOrphanGuard KEEP a lock when a
# reap is refused. So a live foreign claim is left exactly as found and this sweep simply
# stays unpublished, which degrades to today's behaviour (the reader's backstop still
# names it as unattributed load) and never to something worse.
#
# BEST-EFFORT THROUGHOUT. Every entry point rescues and returns nil. A release must never
# die because it could not publish presence — that is `write_lock`'s own posture, kept.
module ReleasePresence
  SWEEP = "sweep"
  SHIP  = "ship"

  # Phase and weight vocabulary, matching bin/lib/agent_presence.rb's WEIGHTS map
  # (suite 1.0 / light 0.25 / idle 0.0) and its `phase == "waiting"` short-circuit to 0.
  PHASE_WORKING = "working"
  PHASE_WAITING = "waiting"
  WEIGHT_SUITE  = "suite"
  WEIGHT_LIGHT  = "light"
  WEIGHT_IDLE   = "idle"

  # What a conductor costs when it is NOT running a suite: git plumbing, `gh` calls,
  # board writes, deploys. Real, but a quarter of a suite — and deliberately not zero,
  # because the claim must stay COUNTED for the reader to attribute its process group and
  # lift the sweep out of `backstop`.
  DEFAULT_WEIGHT = WEIGHT_LIGHT

  class << self
    # `RELEASE_PRESENCE=off` disarms the writer entirely — the escape hatch a deploy
    # tool owes any new file it creates on the operator's machine.
    def enabled?(env = ENV)
      env["RELEASE_PRESENCE"].to_s.strip.downcase != "off"
    end

    # The claim's root: the PRIMARY checkout, never a desk. See the header — a desk's
    # runlock slot is reaped by CertOrphanGuard.preflight, and a primary's is not
    # reachable by any cert at all.
    def claim_root(root)
      value = root.to_s
      marker = value.index("/.worktrees/")
      marker ? value[0...marker] : value
    end

    # Open the claim. Returns the path written, or nil when it published nothing
    # (disarmed, no root, a live foreign claim, or any IO failure).
    def open!(kind:, root:, lane: nil, phase: PHASE_WORKING, weight: DEFAULT_WEIGHT,
              db: nil, session_id: nil, agent: nil, command: nil, table: nil, now: Time.now)
      return nil unless enabled?

      target = claim_root(root)
      return nil if target.empty?
      return nil if foreign_live?(target, table)

      # THE RECORDED PGID NAMES THIS PROCESS, NOT THE GROUP IT WAS LAUNCHED IN.
      #
      # `Process.getpgrp` here would record a group this writer DOES NOT OWN. `bin/release`
      # never calls `setpgrp`, so its group is whatever launched it — under the agent
      # harness a `/bin/zsh -c …` wrapper it shares with `gh run watch` and the rest of the
      # session. Every cert runlock before this one named a group the cert CREATED
      # (`cert_process.rb` spawns each lane with `pgroup: true`), and the identity proof
      # rests on exactly that ownership. Measured on a real `bin/release.rb ship --yes`:
      # pid 61666 in pgid 61388, whose leader was another session's shell.
      #
      # Recording the INHERITED group broke all three of this module's promises at once,
      # each reproduced against the REAL reader (`AgentPresence.grade`), not a stand-in:
      #   * a killed sweep graded :live, not :dead — the wrapper's leader was still alive
      #     and its (pid, lstart) matched, so the `:lane` subject carried it. COUNTED, at
      #     weight 0.25, with no TTL to expire: an UNBOUNDED wedge, the exact opposite of
      #     the "wedge window is zero" rule this module is built on;
      #   * `foreign_live?` then saw that same live leader forever, so every later sweep
      #     published nothing — the feature permanently disabling itself;
      #   * `CertOrphanGuard.decide` graded the corpse :orphan, and `preflight`'s
      #     `reap_group` would SIGTERM/SIGKILL that wrapper group — a bystander measured
      #     holding 5 unrelated processes, including the session's own shell.
      #
      # So the claim names only a subject this process IS. The lane subject collapses onto
      # the cert subject, which costs the two-subject walk (a conductor killed while the
      # suite it spawned SURVIVES is no longer attributed to THIS claim) — and that gap is
      # precisely what the reader's `backstop` covers: `HEAVY_PATTERNS` matches
      # `bin/rails test`, so an orphaned release suite is still reported as heavy load and
      # still forces EXIT_BUSY. Degraded ATTRIBUTION, never silence.
      #
      # The alternative was `Process.setpgrp` before this call, making the group record
      # true by giving the conductor a group it owns. REJECTED for a PRODUCTION DEPLOY
      # TOOL, because it also detaches `bin/release ship` from the signals that stop it:
      # Ctrl-C would stop reaching an interactive `prepare`, and — worse — a harness that
      # kills the session's process group would no longer stop the deploy, leaving Heroku
      # pushes and `release → main` fast-forwards running with no supervisor and no signal
      # path. Today's "a killed session kills the ship, nothing half-deployed, just
      # re-run" is a safety property worth more than orphan-child attribution.
      pid = Process.pid
      started = CertOrphanGuard.process_started_at(pid)
      @state = {
        root: target, kind: kind.to_s, lane: lane, db: db,
        cert_pid: pid, pgid: pid,
        cert_started_at: started,
        pgid_started_at: started,
        session_id: session_id, agent: agent, command: command,
        began_at: now.utc.iso8601, stack: []
      }
      publish(phase: phase, weight: weight, now: now)
    rescue StandardError
      nil
    end

    # Re-publish at a new phase/weight, identity untouched. The claim is the SAME claim;
    # only what it costs has changed.
    def phase!(phase:, weight:, now: Time.now)
      return nil unless open?

      publish(phase: phase, weight: weight, now: now)
    rescue StandardError
      nil
    end

    # Run a block at `phase`/`weight`, then restore whatever was in force. A stack, not a
    # swap, so a nested transition (a CI wait inside a gate, say) cannot strand the claim
    # at the inner phase — the residual staleness the design bounds is a DEAD writer's,
    # never a live one's bookkeeping.
    def with_phase(phase:, weight:)
      unless open?
        return yield
      end

      # BOOKKEEPING IS BEST-EFFORT; THE BLOCK'S OWN EXCEPTION IS NOT.
      #
      # This was the module's only entry point that could raise from its own presence
      # accounting (review, 2026-09-02). `@state` can go nil under the block — `close!`
      # inside it, or a `forget!` — and `@state[:stack]` in the `ensure` then raised
      # NoMethodError FROM the ensure, which REPLACES whatever the block was already
      # raising. A deploy would have died reporting a presence bug instead of the real
      # failure. So each half is guarded separately: the restore can never raise, and
      # `yield` is never rescued — the release's own error must always propagate intact.
      begin
        @state[:stack].push({ phase: @state[:phase], weight: @state[:weight] })
        phase!(phase: phase, weight: weight)
      rescue StandardError
        nil
      end

      begin
        yield
      ensure
        begin
          restored = @state && @state[:stack]&.pop
          phase!(phase: restored[:phase], weight: restored[:weight]) if restored
        rescue StandardError
          nil
        end
      end
    end

    # Clear on graceful exit — AN OPTIMIZATION, NOT THE CORRECTNESS STORY (see header).
    # Deletes only a file that still names US: another conductor may have taken the slot
    # after our claim was graded a corpse, and deleting its record would be the clobber
    # `open!` refuses.
    def close!
      return nil unless open?

      root = @state[:root]
      on_disk = CertOrphanGuard.read_lock(root)
      ours = on_disk &&
             CertOrphanGuard.coerce_pid(on_disk["cert_pid"]) == @state[:cert_pid] &&
             CertOrphanGuard.coerce_pid(on_disk["pgid"]) == @state[:pgid]
      CertOrphanGuard.clear_lock(root) if ours
      @state = nil
      ours ? root : nil
    rescue StandardError
      @state = nil
      nil
    end

    def open? = !@state.nil?

    # Test seam: forget the in-memory claim WITHOUT touching disk, so a test can prove
    # what a SIGKILLed writer leaves behind.
    def forget! = (@state = nil)

    def state = @state

    private

    def publish(phase:, weight:, now: Time.now)
      @state[:phase]  = phase
      @state[:weight] = weight
      CertOrphanGuard.write_lock(
        @state[:root],
        cert_pid: @state[:cert_pid], pgid: @state[:pgid],
        cert_started_at: @state[:cert_started_at], pgid_started_at: @state[:pgid_started_at],
        lane: @state[:lane], db: @state[:db], now: now,
        extra: {
          "kind" => @state[:kind], "phase" => phase, "weight" => weight,
          "session_id" => @state[:session_id], "agent" => @state[:agent],
          "command" => @state[:command], "began_at" => @state[:began_at]
        }
      )
      CertOrphanGuard.lock_path(@state[:root])
    end

    # Is the claim already held by something ALIVE that is not us?
    #
    # The predicate is the reader's COUNTED_GRADES expressed in the guard's own
    # primitives: a subject that is alive and either PROVES it is the recorded process
    # (`:ours`) or cannot be proven either way (`:unprovable`) is treated as live. Every
    # tie breaks toward leaving the incumbent alone, because over-reporting another's
    # claim costs this sweep a row in a report, and under-reporting it destroys a live
    # peer's only local record.
    def foreign_live?(root, table = nil)
      lock = CertOrphanGuard.read_lock(root)
      return false unless lock

      pid  = CertOrphanGuard.coerce_pid(lock["cert_pid"])
      pgid = CertOrphanGuard.coerce_pid(lock["pgid"])
      # Our OWN claim is never foreign. Recognise it by `cert_pid` alone: the writer now
      # records `pgid` as its own pid (see `open!`), so comparing against `Process.getpgrp`
      # here would never match what we wrote and a conductor would refuse to re-open its
      # own slot. If the live process at `cert_pid` is us, the claim is ours by definition.
      return false if pid == Process.pid

      table ||= CertOrphanGuard.process_table
      subjects = [[pid, lock["cert_started_at"]], [pgid, lock["pgid_started_at"]]].reject { |p, _| p.nil? }
      subjects.any? do |subject_pid, recorded|
        process = CertOrphanGuard.live_process(table, subject_pid)
        next true if process.nil? && pgid && CertOrphanGuard.group_members(table, pgid).any?
        next false if process.nil?

        %i[ours unprovable].include?(CertOrphanGuard.identity_of(process, recorded))
      end
    rescue StandardError
      true # cannot read the slot → assume it is held. Never clobber on a bad read.
    end
  end
end
