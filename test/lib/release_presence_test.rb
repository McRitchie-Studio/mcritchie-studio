# frozen_string_literal: true

# A SWEEP MUST PUBLISH, LOCALLY, THAT IT IS CONSUMING THIS MACHINE.
#
# Slice 4 of docs/agents/system/agent-presence.md. The measured cost this closes: a
# 45-minute full-suite run SIGTERMed at its 2700s ceiling having completed 11% of its
# tests, saturated by a `bin/release prepare` sweep that no status command reported.
#
# The sweep was never UNCLAIMED. It already takes a board `assembler` conductor claim
# (answering "is a release live", remotely, on a TTL, and read by exactly one caller in
# the ecosystem) and flocks under `.agents/locks` (invisible to anything not already
# contending for them). Neither answers "is THIS MACHINE saturated", and only that one
# decides whether a peer may launch a suite.
#
# WHAT THESE TESTS PIN, and why each is a property rather than a spelling:
#
#   1. The claim lands where the slice-1 reader ALREADY globs and in the shape it already
#      grades — a claim the reader cannot see closes nothing.
#   2. It carries the OS's (pid, lstart) identity for BOTH subjects, so the READER decides
#      liveness and the claim gets no vote.
#   3. A KILLED writer's claim grades DEAD on the very next read — no timeout to elapse,
#      no renewal to miss, so the wedge window is zero rather than one TTL.
#   4. `open!` REFUSES a live foreign claim instead of clobbering it, and `close!` deletes
#      only a file that still names us. One file per root, two conductors possible.
#   5. `write_lock`'s new `extra:` is byte-identical when empty — the shared atomic writer
#      must not change under every existing cert.
#
# Run directly:
#   ruby -Itest test/lib/release_presence_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/release_presence"
require_relative "../../bin/lib/cert_orphan_guard"

class ReleasePresenceClaimTest < Minitest::Test
  # A pid that is not running. 999_999 exceeds every default pid_max in this house, and
  # it is the same stand-in the cert guard's own reaper tests use.
  DEAD_PID = 999_999

  def setup
    ReleasePresence.forget!
  end

  def teardown
    ReleasePresence.forget!
  end

  def with_root
    Dir.mktmpdir { |dir| yield dir }
  end

  def read_claim(root)
    JSON.parse(File.read(CertOrphanGuard.lock_path(root)))
  end

  # The reader's own liveness rule, expressed in the guard's primitives so this test
  # grades a claim EXACTLY as bin/lib/agent_presence.rb#grade does — not with a
  # look-alike of it.
  def grade_subject(claim, pid_key, start_key, table: CertOrphanGuard.process_table)
    pid = CertOrphanGuard.coerce_pid(claim[pid_key])
    process = CertOrphanGuard.live_process(table, pid)
    return :dead if process.nil?

    CertOrphanGuard.identity_of(process, claim[start_key])
  end

  # --- [unit] the claim is READABLE: right slot, right shape -------------------------

  def test_claim_is_written_to_the_runlock_slot_the_reader_globs
    with_root do |root|
      path = ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root, lane: "release:prepare")

      assert_equal CertOrphanGuard.lock_path(root), path,
                   "the claim must land in the runlock slot — bin/lib/agent_presence.rb globs " \
                   "*/.git/cert-run.json and */.git/worktrees/*/cert-run.json and NOTHING else, so a " \
                   "claim written anywhere else leaves the sweep in the reader's `backstop` as " \
                   "unattributed heavy work, which is the exact gap this slice closes"
      assert_path_exists path
    end
  end

  def test_claim_carries_identity_for_both_subjects_and_the_presence_fields
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root, lane: "release:prepare",
                            session_id: "sess-1", agent: "avi", command: "bin/release prepare")
      claim = read_claim(root)

      # The identity half — the ONLY fields that decide whether any of the others may be
      # believed. BOTH SUBJECTS MUST NAME A PROCESS THIS WRITER IS. `bin/release` never
      # calls setpgrp, so `Process.getpgrp` would name the group it INHERITED from the
      # shell that launched it — a group it does not own, cannot speak for, and must never
      # aim a reaper at. This assertion used to demand exactly that inherited value and so
      # PINNED the defect in place (review, 2026-09-02); it now pins the invariant instead.
      assert_equal Process.pid, claim["cert_pid"]
      assert_equal Process.pid, claim["pgid"],
                   "the group subject must be the writer's OWN pid, not its inherited group"
      refute_equal Process.getpgrp, claim["pgid"],
                   "and specifically NOT Process.getpgrp: under the agent harness that is a " \
                   "/bin/zsh -c wrapper shared with the rest of the session, which outlives " \
                   "this process and would keep a dead claim reading as :live forever"
      refute_nil claim["cert_started_at"], "a claim with no start time can prove nothing and " \
                                          "is graded `unverifiable` rather than trusted"
      refute_nil claim["pgid_started_at"]

      # The presence half — what it costs, and who is holding it.
      assert_equal "sweep", claim["kind"]
      assert_equal ReleasePresence::PHASE_WORKING, claim["phase"]
      assert_equal ReleasePresence::WEIGHT_LIGHT, claim["weight"]
      assert_equal "release:prepare", claim["lane"]
      assert_equal "sess-1", claim["session_id"]
      assert_equal "avi", claim["agent"]
    end
  end

  def test_a_live_claim_grades_ours_through_the_readers_own_rule
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)
      claim = read_claim(root)

      assert_equal :ours, grade_subject(claim, "cert_pid", "cert_started_at"),
                   "the reader must be able to PROVE the claim is the process it names; " \
                   ":unprovable would be counted conservatively but named as unproven"
    end
  end

  # --- [unit] THE KILLED-WRITER RULE -------------------------------------------------

  def test_killed_sweep_claim_grades_dead_with_no_timeout
    with_root do |root|
      # What a SIGKILLed sweep leaves: its file, naming a pid the OS no longer knows.
      # No handler ran, so nothing was cleared — by design.
      CertOrphanGuard.write_lock(root, cert_pid: DEAD_PID, pgid: DEAD_PID,
                                 cert_started_at: "Tue Sep  1 11:05:12 2026",
                                 pgid_started_at: "Tue Sep  1 11:05:12 2026",
                                 lane: "release:prepare",
                                 extra: { "kind" => "sweep", "phase" => "working", "weight" => "suite" })
      claim = read_claim(root)

      assert_path_exists CertOrphanGuard.lock_path(root),
                         "the file MUST survive the writer — it is the only local record naming " \
                         "the workload, and a writer that could clear it on death would not need it"
      assert_equal :dead, grade_subject(claim, "cert_pid", "cert_started_at"),
                   "a corpse must be graded on the VERY NEXT read. This is the property a " \
                   "heartbeat cannot offer: a stale heartbeat is indistinguishable from a slow " \
                   "one until its TTL expires, so the wedge window here is ZERO, not one TTL"
    end
  end

  def test_forget_leaves_the_claim_on_disk_exactly_as_a_kill_would
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)
      ReleasePresence.forget!

      assert_path_exists CertOrphanGuard.lock_path(root)
      refute_predicate ReleasePresence, :open?
    end
  end

  # --- [unit] phase transitions ------------------------------------------------------

  def test_phase_rewrites_cost_and_preserves_identity
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SHIP, root: root, lane: "release:ship")
      before = read_claim(root)

      ReleasePresence.phase!(phase: ReleasePresence::PHASE_WORKING,
                             weight: ReleasePresence::WEIGHT_SUITE)
      after = read_claim(root)

      assert_equal ReleasePresence::WEIGHT_SUITE, after["weight"],
                   "inside a test scope the conductor costs a FULL suite — that is the weight " \
                   "that stops a peer launching one beside it"
      %w[cert_pid pgid cert_started_at pgid_started_at].each do |key|
        assert_equal before[key], after[key],
                     "#{key} must survive a phase change: it is the SAME claim, and only what " \
                     "it costs has changed"
      end
    end
  end

  def test_with_phase_restores_the_previous_phase_even_when_the_block_raises
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)

      assert_raises(RuntimeError) do
        ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WORKING,
                                   weight: ReleasePresence::WEIGHT_SUITE) { raise "gate exploded" }
      end

      assert_equal ReleasePresence::WEIGHT_LIGHT, read_claim(root)["weight"],
                   "a failed gate must not strand the claim at suite weight. The residual " \
                   "staleness this design tolerates is a DEAD writer's, bounded by its own " \
                   "lifetime — never a LIVE writer's bookkeeping"
    end
  end

  def test_waiting_phase_is_published_so_a_parked_conductor_costs_a_peer_nothing
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SHIP, root: root)
      ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WAITING,
                                 weight: ReleasePresence::WEIGHT_IDLE) do
        claim = read_claim(root)

        assert_equal ReleasePresence::PHASE_WAITING, claim["phase"],
                     "a conductor parked on a GitHub Actions poll consumes nothing — cost #4 of " \
                     "the design is two idle processes read as competing certs. The reader " \
                     "short-circuits `phase == waiting` to weight 0 while still COUNTING the " \
                     "claim, so the process group stays attributed instead of falling back into " \
                     "the backstop"
      end
      assert_equal ReleasePresence::PHASE_WORKING, read_claim(root)["phase"]
    end
  end


  # The failure this module must never cause: replacing a deploy's real exception with one
  # from its own bookkeeping. `close!` under the block nils `@state`, and the `ensure` then
  # touched `@state[:stack]` — a NoMethodError raised FROM an ensure, which supersedes the
  # exception already in flight (review, 2026-09-02). The release would have reported a
  # presence bug instead of the deploy failure the operator needs to see.
  def test_with_phase_never_replaces_the_blocks_exception_with_its_own_bookkeeping
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)

      error = assert_raises(RuntimeError) do
        ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WORKING,
                                   weight: ReleasePresence::WEIGHT_SUITE) do
          ReleasePresence.close! # the claim goes away underneath the block
          raise "the deploy failed"
        end
      end

      assert_equal "the deploy failed", error.message,
                   "the caller's exception must arrive intact — presence accounting is " \
                   "best-effort and must never be the thing a release dies reporting"
    end
  end
  def test_with_phase_yields_and_returns_the_block_value_when_no_claim_is_open
    with_root do |_root|
      refute_predicate ReleasePresence, :open?
      result = ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WAITING,
                                          weight: ReleasePresence::WEIGHT_IDLE) { [:out, true] }

      assert_equal [:out, true], result,
                   "run_test_scope and the CI poll wrap their real work in this — a disarmed or " \
                   "unopened claim must be transparent, never a behaviour change in the release"
    end
  end

  # --- [unit] never clobber a live peer ----------------------------------------------

  def test_open_refuses_to_clobber_a_live_foreign_claim
    with_root do |root|
      # A live incumbent: our own group, recorded honestly, under a DIFFERENT pid so the
      # writer cannot mistake it for its own.
      alive = CertOrphanGuard.process_started_at(Process.getpgrp)
      CertOrphanGuard.write_lock(root, cert_pid: DEAD_PID, pgid: Process.getpgrp,
                                 pgid_started_at: alive, lane: "release:ship",
                                 extra: { "kind" => "ship" })

      assert_nil ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root),
                 "a prepare and a ship may legitimately run at once and both root at the same " \
                 "primary. Overwriting the incumbent destroys a live peer's ONLY local record — " \
                 "the same reason CertOrphanGuard KEEPS a lock when a reap is refused"
      assert_equal "ship", read_claim(root)["kind"], "the incumbent must be left exactly as found"
      refute_predicate ReleasePresence, :open?, "and this conductor must know it published nothing"
    end
  end

  def test_open_takes_a_slot_whose_holder_is_a_corpse
    with_root do |root|
      # cert_pid == pgid is EXACTLY the shape `open!` writes (it records its own pid as the
      # group it speaks for), so this fixture is a claim the writer can actually produce.
      # Under the pre-fix writer, which recorded the INHERITED Process.getpgrp, it was not:
      # those two numbers always differed, and equalising them here quietly excluded the
      # `:lane` subject — which is where the defect lived (review, 2026-09-02).
      CertOrphanGuard.write_lock(root, cert_pid: DEAD_PID, pgid: DEAD_PID,
                                 cert_started_at: "Tue Sep  1 11:05:12 2026",
                                 pgid_started_at: "Tue Sep  1 11:05:12 2026",
                                 extra: { "kind" => "sweep" })

      refute_nil ReleasePresence.open!(kind: ReleasePresence::SHIP, root: root),
                 "refusing forever on a dead predecessor would make one killed sweep hide every " \
                 "later one — the file is evidence, not a lock"
      assert_equal Process.pid, read_claim(root)["cert_pid"]
    end
  end

  def test_close_clears_only_a_claim_that_still_names_us
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)
      assert_equal root, ReleasePresence.close!
      refute_path_exists CertOrphanGuard.lock_path(root)
    end
  end

  def test_close_leaves_a_claim_another_conductor_has_taken
    with_root do |root|
      ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)
      # A peer took the slot after ours was graded a corpse (or we were re-nice'd out of
      # it). Deleting its record on our way out is the clobber `open!` refuses.
      CertOrphanGuard.write_lock(root, cert_pid: DEAD_PID, pgid: DEAD_PID,
                                 extra: { "kind" => "ship" })

      assert_nil ReleasePresence.close!
      assert_equal "ship", read_claim(root)["kind"]
    end
  end

  # --- [unit] the collision-safety property -------------------------------------------

  def test_claim_root_normalizes_a_desk_path_to_its_primary_checkout
    desk = "/Users/alex/projects/mcritchie-studio/.worktrees/some-task"

    assert_equal "/Users/alex/projects/mcritchie-studio", ReleasePresence.claim_root(desk),
                 "a DESK's runlock slot is read by CertOrphanGuard.preflight, which REAPS — it " \
                 "SIGKILLs a process group a runlock names once it can prove the group is ours. " \
                 "A sweep claim sitting there would be a sweep-killing landmine. A PRIMARY is " \
                 "NOT out of that reach — CertRootGuard.refusal is gated on a slug while the " \
                 "orphan preflight is unconditional, so a slug-less cert (what --install-hook " \
                 "writes into .git/hooks/pre-push) preflights a primary anyway. Safety comes " \
                 "from the claim naming only its own writer, not from where it sits"
    assert_equal "/Users/alex/projects/mcritchie-studio",
                 ReleasePresence.claim_root("/Users/alex/projects/mcritchie-studio")
  end

  def test_disarmed_by_env_publishes_nothing
    with_root do |root|
      begin
        ENV["RELEASE_PRESENCE"] = "off"

        assert_nil ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: root)
        refute_path_exists CertOrphanGuard.lock_path(root)
      ensure
        ENV.delete("RELEASE_PRESENCE")
      end
    end
  end

  # --- [unit] the shared writer must not change under existing certs -------------------

  def test_write_lock_with_no_extra_is_byte_identical_to_the_original_record
    with_root do |root|
      now = Time.now
      CertOrphanGuard.write_lock(root, cert_pid: 4321, pgid: 4300, cert_started_at: "a",
                                 pgid_started_at: "b", lane: "spine", db: "x_test", now: now)
      body = File.read(CertOrphanGuard.lock_path(root))

      assert_equal JSON.generate("cert_pid" => 4321, "cert_started_at" => "a",
                                 "pgid" => 4300, "pgid_started_at" => "b",
                                 "lane" => "spine", "db" => "x_test",
                                 "started_at" => now.utc.iso8601),
                   body,
                   "every cert in the house writes through this method. An empty `extra:` must " \
                   "produce exactly the record it always did, key order included"
    end
  end


  # The `extra:` overlay may ENRICH a lock; it may never restate WHO the lock names. Every
  # reader in this house trusts the identity block unconditionally — it is the whole basis
  # on which a claim is graded live or dead — so a caller able to forge `cert_pid` could
  # make the grader vouch for a process the writer is not (review, 2026-09-02).
  def test_extra_cannot_forge_the_identity_the_readers_trust
    with_root do |root|
      CertOrphanGuard.write_lock(root, cert_pid: 4321, pgid: 4321,
                                 cert_started_at: "real", pgid_started_at: "real",
                                 extra: { "cert_pid" => 9999, "pgid" => 9999,
                                          "cert_started_at" => "forged",
                                          "pgid_started_at" => "forged",
                                          "kind" => "sweep" })
      claim = JSON.parse(File.read(CertOrphanGuard.lock_path(root)))

      assert_equal 4321, claim["cert_pid"], "the overlay must not be able to rename the writer"
      assert_equal 4321, claim["pgid"]
      assert_equal "real", claim["cert_started_at"],
                   "nor restate the start time that PROVES the pid is not a recycled stranger"
      assert_equal "real", claim["pgid_started_at"]
      assert_equal "sweep", claim["kind"],
                   "while everything the overlay legitimately carries still lands"
    end
  end
  def test_write_lock_drops_nil_extras_rather_than_recording_absent_facts
    with_root do |root|
      CertOrphanGuard.write_lock(root, cert_pid: 1, pgid: 2,
                                 extra: { "kind" => "sweep", "agent" => nil })
      claim = JSON.parse(File.read(CertOrphanGuard.lock_path(root)))

      assert_equal "sweep", claim["kind"]
      refute_includes claim.keys, "agent",
                      "a null field invites a reader to print `agent: ` — absence should be absent"
    end
  end
end
