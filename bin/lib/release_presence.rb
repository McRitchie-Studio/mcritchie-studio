# frozen_string_literal: true

require "json"
require "time"
require_relative "presence_claim"

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
# SIGKILLed sweep leaves its file behind — by design — and it is graded a corpse on the
# very next read, with no timeout to elapse and no renewal to miss. THE WEDGE WINDOW IS
# ZERO, not one TTL.
#
# ------------------------------------------------------------------------------------
# WHERE THE CLAIM LIVES — the session-marker namespace, via PresenceClaim
# ------------------------------------------------------------------------------------
# `.agents/sessions/<key>.presence-<kind>-<pid>`, which is §4's own nomination and what
# slice 3's `bin/lib/presence_claim.rb` already writes for `bin/ship`. This module owns
# no file format and no writer: it is the release CLI's phase vocabulary wrapped around
# that shared claim.
#
# AN EARLIER REVISION OF THIS FILE PUBLISHED INTO THE CERT RUNLOCK SLOT
# (`CertOrphanGuard.lock_path(root)`), and that was wrong — but it was not arbitrary,
# and the reason it was ever right is worth keeping, because it is what changed:
# §5(c) of the design says sweeps are read by "the same glob and the same grader" as
# certs, and when this slice was written `AgentPresence::CLAIM_GLOBS` held exactly two
# `cert-run.json` patterns. A claim at §4's path was INVISIBLE to the reader, so it
# would have left the sweep sitting in the reader's `backstop` as unattributed heavy
# work — closing none of cost #3.
#
# That premise is now false. `certs-publish-no-phase` (PR #1161) taught the reader the
# marker namespace directly — `bin/lib/agent_presence.rb`, `claim_paths`:
#
#     supervisors = File.join(".agents", "sessions", "*.presence-*")
#     (CLAIM_GLOBS + [supervisors]).flat_map { ... }
#
# under a comment that states the safety property in four words: "Read here, reaped
# nowhere." So the marker namespace is visible to the READER and invisible to the
# REAPER by construction, and the tradeoff that forced the runlock slot is gone.
#
# WHY THAT SEPARATION IS LOAD-BEARING AND NOT A FILING PREFERENCE.
# `CertOrphanGuard.preflight` REAPS: it SIGKILLs the process group a `cert-run.json`
# names once it can prove the group is ours. A release-lane claim in that slot is a
# loaded gun pointed at a production deploy, and it is NOT made safe by choosing a
# primary checkout over a desk — an earlier version of this header claimed exactly that
# and was FALSE (review, 2026-09-02). `CertRootGuard.refusal` is gated on a slug
# (`bin/fast-check:180`, `bin/full-suite-check:204`) while the orphan preflight is
# UNCONDITIONAL (`bin/fast-check:372`, `bin/full-suite-check:448`), so every slug-less
# cert skips the root guard and preflights anyway — including the
# `bin/full-suite-check --print` that `--install-hook` writes into
# `.git/hooks/pre-push`. The correct defence is the one the namespace gives for free:
# be somewhere the reaper does not read.
#
# WHAT THE MOVE RETIRED, said plainly so nobody re-adds it. The runlock is ONE FILE PER
# ROOT, so the old writer had to refuse rather than clobber when a `prepare` and a
# `ship` ran at once, and the loser published nothing. The marker namespace is one file
# per PROCESS, so there is no shared slot, nothing to contend for, and BOTH conductors
# now publish and are BOTH counted — which is the accurate answer to "how saturated is
# this machine", not merely a simpler one. The `foreign_live?` guard and its
# never-clobber rule went with the slot they defended.
#
# ------------------------------------------------------------------------------------
# WHAT THIS MODULE STILL DECIDES FOR ITSELF — `pgid: pid`
# ------------------------------------------------------------------------------------
# `PresenceClaim.open` defaults `pgid` to `Process.getpgid(pid)`, which is right for
# `bin/ship`: ship spawns `bin/fast-check` with `system` and no `pgroup:`, so the runner
# lands in the ship's OWN group and the group is a true second subject. `bin/release` is
# NOT shaped that way. It never calls `setpgrp`, so its group is whatever LAUNCHED it —
# under the agent harness a `/bin/zsh -c …` wrapper shared with the rest of the session
# (measured: `bin/release.rb ship --yes` at pid 61666 in pgid 61388, a group whose leader
# was another session's shell).
#
# Recording that inherited group makes a KILLED sweep grade `:live`, forever: the wrapper
# outlives the conductor, its `(pid, lstart)` still matches, and the reader's second
# subject carries the corpse. Counted, at weight 0.25, with no TTL to expire — an
# UNBOUNDED WEDGE, the exact inversion of the killed-writer rule this module rests on.
# Reproduced against the real `AgentPresence.grade`, not a stand-in.
#
# So the claim names only a subject this process IS. The price is the two-subject walk: a
# conductor killed while the suite it spawned SURVIVES is no longer attributed to THIS
# claim. That gap is exactly what the reader's `backstop` covers — `HEAVY_PATTERNS`
# matches `bin/rails test`, so an orphaned release suite is still reported as heavy load
# and still forces EXIT_BUSY. Degraded ATTRIBUTION, never silence.
#
# `Process.setpgrp` before the call would make the inherited-group record true by giving
# the conductor a group it owns. REJECTED, and this is the reasoning to keep: it detaches
# `bin/release ship` from the signals that stop it. Ctrl-C would stop reaching an
# interactive `prepare`, and a harness that kills the session's process group would no
# longer stop the deploy — leaving Heroku pushes and a `release → main` fast-forward
# running unsupervised with no signal path. Today's "a killed session kills the ship,
# nothing half-deployed, just re-run" is worth more than orphan-child attribution.
#
# BEST-EFFORT THROUGHOUT, WITH ONE STATED EXCEPTION. Every entry point rescues
# StandardError and returns nil, so no IO failure, missing directory or unreadable process
# table can take down a release.
#
# THE EXCEPTION, named rather than glossed: `SessionMarkers.write` is FAIL-CLOSED on a
# SANDBOX violation. With `TASK_USAGE_SANDBOX` armed and `CLAUDE_PROJECTS_DIR` unset it
# calls `abort`, which raises SystemExit — not a StandardError — so it passes straight
# through the rescues here and stops the process. That is deliberate and it is not this
# module's to soften: the guard exists because an unpinned store once wrote ~1.9 billion
# tokens into the operator's LIVE cost data, and a writer taught to shrug off a sandbox
# violation is the leak wearing a rescue. The condition is reachable only from a TEST
# harness (test/support/task_usage_sandbox.rb arms the flag for the whole process), and
# the pin belongs there — `OutboundSeams.env` supplies it for every bin/ child.
module ReleasePresence
  SWEEP = "sweep"
  SHIP  = "ship"

  # Phase and weight vocabulary. These are PresenceClaim's constants, re-exported under
  # the names `bin/release.rb` reads — one vocabulary, spelled once, so a phase this
  # module publishes can never drift from the phase the reader honours.
  PHASE_WORKING = PresenceClaim::WORKING
  PHASE_WAITING = PresenceClaim::WAITING
  WEIGHT_SUITE  = PresenceClaim::SUITE
  WEIGHT_LIGHT  = PresenceClaim::LIGHT
  WEIGHT_IDLE   = PresenceClaim::IDLE

  # What a conductor costs when it is NOT running a suite: git plumbing, `gh` calls,
  # board writes, deploys. Real, but a quarter of a suite — and deliberately not zero,
  # because the claim must stay COUNTED for the reader to attribute its process group and
  # lift the sweep out of `backstop`.
  DEFAULT_WEIGHT = WEIGHT_LIGHT

  # ----------------------------------------------------------------------------------
  # WHO PAYS FOR A TEST SCOPE — derived from the registry, never from the call site
  # ----------------------------------------------------------------------------------
  # A presence weight answers exactly one question: HOW MUCH OF *THIS BOX* IS THIS
  # WORK USING. `config/devops_test_suites.yml` already describes every release scope
  # with `host:` and `tier:`, so the answer is derivable there — and derivation is the
  # point. The alternative (a `weight:` keyword passed at each `run_test_scope` call
  # site) puts the fact somewhere a NEW scope does not have to visit, so the next scope
  # added silently inherits `suite` and the over-reporting returns. Here, a new scope
  # declares its cost by declaring the metadata it must declare anyway.
  #
  # `host` is very nearly the discriminator on its own: `local` means this box runs the
  # work, `qa`/`production` mean the work runs on a Heroku dyno while the conductor holds
  # a socket open. It is not sufficient, because `host` names the TARGET, not the payer —
  # `prod_smoke_seal` is `host: production` and runs `npx playwright test` LOCALLY
  # (`bin/prod-smoke:77`), against a production URL. So the rule reads BOTH fields and is
  # written to fail toward `suite`:
  #
  #   a scope is cheap  ⟺  its host is not local  AND  its tier is one that executes
  #                        somewhere else — `smoke` (a curl poll) or `hook` (`heroku run`)
  #
  # Everything else — every local host, every unrecognised tier, a missing registry
  # entry, a malformed one — is `suite`. That default is deliberate and matches
  # `AgentPresence::UNKNOWN_WEIGHT`: over-reporting cost makes a peer wait for a machine
  # that was actually free, and under-reporting it lets a peer launch a suite into a
  # saturated box, which is cost #3 all over again.
  REMOTE_TIERS = %w[smoke hook].freeze

  class << self
    # `RELEASE_PRESENCE=off` disarms the writer entirely — the escape hatch a deploy
    # tool owes any new file it creates on the operator's machine.
    def enabled?(env = ENV)
      env["RELEASE_PRESENCE"].to_s.strip.downcase != "off"
    end

    # The presence weight for one registered release scope, from its registry row (the
    # `release_scopes:` hash `bin/release.rb#scope_meta` returns). See REMOTE_TIERS.
    # Anything it cannot read confidently costs a full suite.
    def scope_weight(meta)
      row = meta.is_a?(Hash) ? meta : {}
      host = row["host"].to_s.strip.downcase
      tier = row["tier"].to_s.strip.downcase
      return WEIGHT_LIGHT if !host.empty? && host != "local" && REMOTE_TIERS.include?(tier)

      WEIGHT_SUITE
    end

    # The claim's ROOT — a REPORTING field, and only that. It normalizes a desk path to
    # its primary checkout so the row names the repo rather than whichever workspace the
    # conductor happened to stand in (`bin/release` runs from the primary; its ship
    # workspace is a `.worktrees/_ship` desk). Nothing about SAFETY depends on it any
    # more: the claim is out of the runlock namespace entirely, so where it roots cannot
    # put it in front of a reaper. The earlier version of this method carried that
    # justification and it was false even then — see the header.
    def claim_root(root)
      value = root.to_s
      marker = value.index("/.worktrees/")
      marker ? value[0...marker] : value
    end

    # Open the claim. Returns the marker path written, or nil when it published nothing
    # (disarmed, no root, or any IO failure).
    def open!(kind:, root:, lane: nil, phase: PHASE_WORKING, weight: DEFAULT_WEIGHT,
              session_id: nil, task_slug: nil, projects_dir: nil, env: ENV, now: Time.now)
      return nil unless enabled?(env)

      target = claim_root(root)
      return nil if target.empty?

      pid = Process.pid
      # pgid: pid — NOT PresenceClaim's `Process.getpgid` default. See the header; this is
      # the one decision this module makes differently from `bin/ship`, and it is what
      # keeps a killed sweep gradeable as a corpse.
      @claim = PresenceClaim.open(kind: kind, root: target, projects_dir: projects_dir,
                                  session_id: session_id, task_slug: task_slug,
                                  pid: pid, pgid: pid, env: env, now: now)
      @lane = lane
      @stack = []
      publish(phase: phase, weight: weight, now: now)
    rescue StandardError
      @claim = nil
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
      return yield unless open?

      # BOOKKEEPING IS BEST-EFFORT; THE BLOCK'S OWN EXCEPTION IS NOT.
      #
      # This was the module's only entry point that could raise from its own presence
      # accounting (review, 2026-09-02). The claim can go nil under the block — `close!`
      # inside it, or a `forget!` — and the `ensure` then raised NoMethodError FROM the
      # ensure, which REPLACES whatever the block was already raising. A deploy would have
      # died reporting a presence bug instead of the real failure. So each half is guarded
      # separately: the restore can never raise, and `yield` is never rescued — the
      # release's own error must always propagate intact.
      begin
        @stack.push({ phase: @claim.phase, weight: @claim.weight })
        phase!(phase: phase, weight: weight)
      rescue StandardError
        nil
      end

      begin
        yield
      ensure
        begin
          restored = @stack&.pop
          phase!(phase: restored[:phase], weight: restored[:weight]) if restored && open?
        rescue StandardError
          nil
        end
      end
    end

    # Clear on graceful exit — AN OPTIMIZATION, NOT THE CORRECTNESS STORY (see header).
    #
    # It can only ever delete OUR OWN record, and that is now structural rather than a
    # check we remember to perform: the marker is keyed by this process's session and pid
    # (`PresenceClaim#suffix`), so no other conductor's claim is addressable from here.
    # The old writer shared ONE slot per root with every other conductor and had to prove
    # the file still named it before unlinking; there is nothing left to prove.
    def close!
      return nil unless open?

      path = @claim.clear
      @claim = nil
      @stack = []
      path
    rescue StandardError
      @claim = nil
      @stack = []
      nil
    end

    def open? = !@claim.nil?

    # Test seam: forget the in-memory claim WITHOUT touching disk, so a test can prove
    # what a SIGKILLed writer leaves behind.
    def forget!
      @claim = nil
      @stack = []
      nil
    end

    # Test/reporting seam: the live claim object, or nil.
    def claim = @claim

    private

    # Publish, and REPORT WHAT ACTUALLY HAPPENED. `PresenceClaim#publish` returns nil when
    # the write failed, and this method returns that nil rather than a path — an earlier
    # revision returned the lock path unconditionally, so `open!` reported success on a
    # write it had not performed (review, 2026-09-02).
    def publish(phase:, weight:, now: Time.now)
      @claim.publish(phase: phase, weight: weight, lane: @lane, now: now)
    end
  end
end
