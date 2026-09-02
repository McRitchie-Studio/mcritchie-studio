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
#   1. The claim lands where the slice-1 reader ALREADY globs — asserted by calling that
#      reader, not by restating its glob. A claim the reader cannot see closes nothing.
#   2. It carries the OS's (pid, lstart) identity for BOTH subjects, and BOTH name a
#      process this writer IS. `bin/release` inherits its process group, so recording
#      that group makes a killed sweep read `:live` forever.
#   3. A KILLED writer's claim grades DEAD on the very next read — no timeout to elapse,
#      no renewal to miss, so the wedge window is zero rather than one TTL.
#   4. Two conductors at once BOTH publish and are BOTH counted. This REPLACED an
#      earlier never-clobber rule: the claim used to share one runlock slot per root, so
#      a second conductor had to refuse and publish nothing. In the marker namespace
#      there is no shared slot, and counting both is the accurate answer.
#   5. A scope's presence weight comes from the REGISTRY, so a scope added later cannot
#      silently inherit `suite` from a call site nobody revisits.
#
# The tier boundary: everything here grades hand-built claims or claims this process
# wrote. The property the whole design rests on — that a REAL SIGKILL leaves a corpse the
# REAL reader recognises — is not provable at this tier and lives in
# test/lib/release_presence_integration_test.rb.
#
# Run directly:
#   ruby -Itest test/lib/release_presence_test.rb

require "minitest/autorun"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/release_presence"
require_relative "../../bin/lib/cert_orphan_guard"
require_relative "../../bin/lib/agent_presence"

class ReleasePresenceClaimTest < Minitest::Test
  # A pid that is not running. 999_999 exceeds every default pid_max in this house, and
  # it is the same stand-in the cert guard's own reaper tests use.
  DEAD_PID = 999_999

  SESSION = "c51e8d13-0000-4000-8000-0123456789ab"
  # The marker store's sandbox is OFF here and the store is PINNED to a tmpdir on every
  # call, which is what keeps a test run out of the operator's live `.agents`.
  SANDBOX_OFF = { "TASK_USAGE_SANDBOX" => "0" }.freeze

  def setup
    ReleasePresence.forget!
  end

  def teardown
    ReleasePresence.forget!
  end

  # Both roots a claim needs, and they are DIFFERENT things: `store` is the projects dir
  # the marker is written under (what the reader globs), `root` is the repo path the claim
  # REPORTS. Conflating them is how a test can pass while the reader sees nothing.
  def with_store
    Dir.mktmpdir { |store| yield(store, File.join(store, "mcritchie-studio")) }
  end

  def open!(store, kind: ReleasePresence::SWEEP, root: nil, **kwargs)
    ReleasePresence.open!(kind: kind, root: root || File.join(store, "mcritchie-studio"),
                          projects_dir: store, session_id: SESSION, env: SANDBOX_OFF, **kwargs)
  end

  def claim_files(store)
    Dir.glob(File.join(store, ".agents", "sessions", "*.presence-*")).sort
  end

  def read_claim(store)
    JSON.parse(File.read(claim_files(store).fetch(0)))
  end

  # THE SHIPPED READER, not a restatement of it. `AgentPresence.claims` performs the glob,
  # the parse and the grade exactly as `bin/agent-presence` does, so a claim that fails to
  # appear here is a claim that closes nothing — which is the failure mode that put the
  # first revision of this module in the wrong namespace.
  def reader_claims(store, table: CertOrphanGuard.process_table)
    AgentPresence.claims(root: store, table: table)
  end

  # --- [unit] the claim is READABLE: right namespace, right shape --------------------

  def test_claim_lands_where_the_shipped_reader_globs_and_not_in_a_runlock_slot
    with_store do |store, root|
      path = open!(store, lane: "release:prepare")

      assert_equal [path], claim_files(store),
                   "the claim belongs in the session-marker namespace — " \
                   ".agents/sessions/<key>.presence-<kind>-<pid>, which is §4's own nomination"
      refute_path_exists CertOrphanGuard.lock_path(root),
                         "and NOT in the cert runlock slot. CertOrphanGuard.preflight REAPS " \
                         "whatever a cert-run.json names — it SIGKILLs that process group — so a " \
                         "release-lane claim there points a reaper at a production deploy. The " \
                         "namespace separation is the safety property (agent_presence.rb: 'Read " \
                         "here, reaped nowhere'), not a filing preference"

      found = reader_claims(store)

      assert_equal 1, found.size, "the shipped reader must FIND it — a claim it cannot see " \
                                  "leaves the sweep in the reader's `backstop` as unattributed " \
                                  "heavy work, closing none of cost #3"
      assert_equal "sweep", found.first[:kind],
                   "and must recognise its kind: AgentPresence::SUPERVISOR_KINDS already holds " \
                   "'sweep', so no reader change was needed for this at all"
    end
  end

  def test_claim_carries_identity_for_both_subjects_and_the_presence_fields
    with_store do |store, _root|
      open!(store, lane: "release:prepare")
      claim = read_claim(store)

      # The identity half — the ONLY fields that decide whether any of the others may be
      # believed. BOTH SUBJECTS MUST NAME A PROCESS THIS WRITER IS. `bin/release` never
      # calls setpgrp, so `PresenceClaim`'s own `Process.getpgid` default would name the
      # group it INHERITED from the shell that launched it — a group it does not own and
      # cannot speak for, whose leader OUTLIVES it. An earlier assertion here demanded
      # exactly that inherited value and so PINNED the defect in place (review 2026-09-02).
      assert_equal Process.pid, claim["pid"]
      assert_equal claim["pid"], claim["pgid"],
                   "the group subject must collapse onto the writer's own pid. If it names " \
                   "the INHERITED group instead, a SIGKILLed sweep grades :live forever — the " \
                   "wrapper's leader is still alive and its (pid, lstart) still matches — which " \
                   "is an UNBOUNDED wedge, the exact inversion of the killed-writer rule"
      assert_equal Process.pid, claim["pgid"]
      refute_nil claim["pid_started_at"], "a claim with no start time can prove nothing and is " \
                                         "graded `unverifiable` rather than trusted"
      refute_nil claim["pgid_started_at"]

      # The presence half — what it costs, and who is holding it.
      assert_equal "sweep", claim["kind"]
      assert_equal ReleasePresence::PHASE_WORKING, claim["phase"]
      assert_equal ReleasePresence::WEIGHT_LIGHT, claim["weight"]
      assert_equal "release:prepare", claim["lane"]
      assert_equal SESSION, claim["session_id"]
    end
  end

  def test_a_live_claim_is_graded_live_and_consumes_capacity
    with_store do |store, _root|
      open!(store)
      found = reader_claims(store)

      assert_equal :live, found.first[:grade],
                   "the reader must be able to PROVE the claim is the process it names; " \
                   ":unverifiable would be counted conservatively but named as unproven"
      assert_operator AgentPresence.consumed(found), :>, 0.0,
                      "a working conductor is not free — it must show up in the arithmetic a " \
                      "peer uses to decide whether to launch"
    end
  end

  # --- [unit] THE KILLED-WRITER RULE -------------------------------------------------

  def test_killed_sweep_claim_survives_its_writer_and_grades_dead_with_no_timeout
    with_store do |store, _root|
      # What a SIGKILLed sweep leaves: its file, naming a pid the OS no longer knows. No
      # handler ran, so nothing was cleared — by design.
      open!(store)
      path = claim_files(store).fetch(0)
      corpse = JSON.parse(File.read(path)).merge("pid" => DEAD_PID, "pgid" => DEAD_PID)
      File.write(path, "#{JSON.generate(corpse)}\n")

      found = reader_claims(store)

      assert_path_exists path,
                         "the file MUST survive the writer — it is the only local record naming " \
                         "the workload, and a writer that could clear it on death would not need it"
      assert_equal :dead, found.first[:grade],
                   "a corpse must be graded on the VERY NEXT read. This is the property a " \
                   "heartbeat cannot offer: a stale heartbeat is indistinguishable from a slow " \
                   "one until its TTL expires, so the wedge window here is ZERO, not one TTL"
      assert_in_delta 0.0, AgentPresence.consumed(found), 0.0001,
                      "and it must free the capacity it was holding, immediately"
    end
  end

  def test_forget_leaves_the_claim_on_disk_exactly_as_a_kill_would
    with_store do |store, _root|
      open!(store)
      ReleasePresence.forget!

      refute_empty claim_files(store)
      refute_predicate ReleasePresence, :open?
    end
  end

  # --- [unit] phase transitions ------------------------------------------------------

  def test_phase_rewrites_cost_and_preserves_identity
    with_store do |store, _root|
      open!(store, kind: ReleasePresence::SHIP, lane: "release:ship")
      before = read_claim(store)

      ReleasePresence.phase!(phase: ReleasePresence::PHASE_WORKING,
                             weight: ReleasePresence::WEIGHT_SUITE)
      after = read_claim(store)

      assert_equal ReleasePresence::WEIGHT_SUITE, after["weight"],
                   "inside a local test scope the conductor costs a FULL suite — that is the " \
                   "weight that stops a peer launching one beside it"
      assert_equal 1, claim_files(store).size,
                   "a phase change REWRITES the one claim rather than leaving a trail of " \
                   "contradicting ones — the marker is keyed by pid, not by phase"
      %w[pid pgid pid_started_at pgid_started_at began_at].each do |key|
        assert_equal before[key], after[key],
                     "#{key} must survive a phase change: it is the SAME claim, and only what " \
                     "it costs has changed"
      end
    end
  end

  def test_with_phase_restores_the_previous_phase_even_when_the_block_raises
    with_store do |store, _root|
      open!(store)

      assert_raises(RuntimeError) do
        ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WORKING,
                                   weight: ReleasePresence::WEIGHT_SUITE) { raise "gate exploded" }
      end

      assert_equal ReleasePresence::WEIGHT_LIGHT, read_claim(store)["weight"],
                   "a failed gate must not strand the claim at suite weight. The residual " \
                   "staleness this design tolerates is a DEAD writer's, bounded by its own " \
                   "lifetime — never a LIVE writer's bookkeeping"
    end
  end

  def test_waiting_phase_is_published_so_a_parked_conductor_costs_a_peer_nothing
    with_store do |store, _root|
      open!(store, kind: ReleasePresence::SHIP)
      ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WAITING,
                                 weight: ReleasePresence::WEIGHT_IDLE) do
        assert_equal ReleasePresence::PHASE_WAITING, read_claim(store)["phase"],
                     "a conductor parked on a GitHub Actions poll consumes nothing — cost #4 of " \
                     "the design is two idle processes read as competing certs. The reader " \
                     "short-circuits `phase == waiting` to weight 0 while still COUNTING the " \
                     "claim, so the process group stays attributed instead of falling into the " \
                     "backstop"
        assert_in_delta 0.0, AgentPresence.consumed(reader_claims(store)), 0.0001,
                        "and the READER must agree — this is the whole point of publishing it"
      end
      assert_equal ReleasePresence::PHASE_WORKING, read_claim(store)["phase"]
    end
  end

  # The failure this module must never cause: replacing a deploy's real exception with one
  # from its own bookkeeping. `close!` under the block drops the claim, and the `ensure`
  # then touched it — a NoMethodError raised FROM an ensure, which supersedes the exception
  # already in flight (review, 2026-09-02). The release would have reported a presence bug
  # instead of the deploy failure the operator needs to see.
  def test_with_phase_never_replaces_the_blocks_exception_with_its_own_bookkeeping
    with_store do |store, _root|
      open!(store)

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
    refute_predicate ReleasePresence, :open?
    result = ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WAITING,
                                        weight: ReleasePresence::WEIGHT_IDLE) { [:out, true] }

    assert_equal [:out, true], result,
                 "run_test_scope, the CI poll and the repo_script deploy all wrap their real " \
                 "work in this — a disarmed or unopened claim must be transparent, never a " \
                 "behaviour change in the release"
  end

  # --- [unit] two conductors, two claims, both counted --------------------------------

  # THE PROPERTY THAT CHANGED WITH THE NAMESPACE, pinned so nobody restores the old one.
  #
  # While the claim lived in `CertOrphanGuard.lock_path(root)` there was ONE slot per root,
  # so a `prepare` and a `ship` running at once contended for it: the writer had to refuse
  # rather than clobber, and the loser published NOTHING (it stayed visible only through
  # the reader's backstop, as unattributed load). The marker namespace is keyed by session
  # and pid, so two conductors are two files and there is nothing to contend for. Both
  # publish, and a peer sees the machine's REAL cost instead of one conductor's half of it.
  def test_two_concurrent_conductors_both_publish_and_are_both_counted
    with_store do |store, _root|
      # A live peer, written as another process would write it: same store, a different
      # pid, and honest identity so the reader grades it live.
      peer_pid = spawn_sleeper
      PresenceClaim.open(kind: ReleasePresence::SHIP, root: File.join(store, "mcritchie-studio"),
                         projects_dir: store, session_id: "peer-session",
                         pid: peer_pid, pgid: peer_pid, env: SANDBOX_OFF)
                   .publish(phase: ReleasePresence::PHASE_WORKING,
                            weight: ReleasePresence::WEIGHT_LIGHT, lane: "release:ship")

      mine = open!(store, lane: "release:prepare")

      assert_equal 2, claim_files(store).size,
                   "a prepare and a ship may legitimately run at once. One file per PROCESS " \
                   "means neither has to lose — the old one-slot-per-root shape made the second " \
                   "conductor publish nothing at all"
      refute_nil mine, "and this conductor must know that it published"

      found = reader_claims(store)
      kinds = found.select { |c| AgentPresence::COUNTED_GRADES.include?(c[:grade]) }.map { |c| c[:kind] }

      assert_equal %w[ship sweep], kinds.sort,
                   "BOTH must be counted. Under-reporting is the expensive direction: it is what " \
                   "lets a peer launch a suite into a box two conductors are already using"
    ensure
      kill_sleeper(peer_pid)
    end
  end

  def test_close_clears_this_conductors_own_claim
    with_store do |store, _root|
      open!(store)
      refute_nil ReleasePresence.close!
      assert_empty claim_files(store),
                   "clearing on graceful exit is an OPTIMIZATION — correctness is the reader " \
                   "grading a corpse — but the tidy path must still work"
      refute_predicate ReleasePresence, :open?
    end
  end

  # --- [unit] reporting + the disarm ---------------------------------------------------

  def test_claim_root_normalizes_a_desk_path_to_its_primary_checkout
    desk = "/Users/alex/projects/mcritchie-studio/.worktrees/some-task"

    assert_equal "/Users/alex/projects/mcritchie-studio", ReleasePresence.claim_root(desk),
                 "the root is a REPORTING field: it should name the repo, not whichever " \
                 "workspace the conductor stood in (a ship works out of a .worktrees/_ship " \
                 "desk). It is no longer a safety mechanism — an earlier revision justified it " \
                 "as keeping the claim out of a reaped slot, which was false even then, and is " \
                 "now moot because the claim is not in a runlock namespace at all"
    assert_equal "/Users/alex/projects/mcritchie-studio",
                 ReleasePresence.claim_root("/Users/alex/projects/mcritchie-studio")
  end

  def test_disarmed_by_env_publishes_nothing
    with_store do |store, _root|
      assert_nil ReleasePresence.open!(kind: ReleasePresence::SWEEP,
                                       root: File.join(store, "mcritchie-studio"),
                                       projects_dir: store, session_id: SESSION,
                                       env: SANDBOX_OFF.merge("RELEASE_PRESENCE" => "off"))
      assert_empty claim_files(store),
                   "RELEASE_PRESENCE=off is the escape hatch a deploy tool owes any new file it " \
                   "creates on the operator's machine"
    end
  end

  # --- [unit] a scope's cost comes from the registry, not from a call site --------------

  # WHY THIS IS DERIVED RATHER THAN PASSED. The rejected alternative was a `weight:` keyword
  # on `run_test_scope` with the four remote scopes passing `light`. It fixes today's table
  # and re-breaks tomorrow's: a scope added later does not visit those call sites, so it
  # inherits `suite` in silence and the over-reporting returns. Deriving it from `host`/`tier`
  # puts the fact where a new scope must already write its metadata.
  def test_scope_weight_is_light_only_when_the_work_executes_on_another_host
    assert_equal ReleasePresence::WEIGHT_LIGHT,
                 ReleasePresence.scope_weight("host" => "qa", "tier" => "smoke"),
                 "a /up curl poll costs this box a socket; the QA dyno does the booting"
    assert_equal ReleasePresence::WEIGHT_LIGHT,
                 ReleasePresence.scope_weight("host" => "production", "tier" => "hook"),
                 "`heroku run` executes on a remote one-off dyno, not here"
    assert_equal ReleasePresence::WEIGHT_SUITE,
                 ReleasePresence.scope_weight("host" => "local", "tier" => "full"),
                 "a local suite is the whole reason this weight exists"
    assert_equal ReleasePresence::WEIGHT_SUITE,
                 ReleasePresence.scope_weight("host" => "production", "tier" => "e2e"),
                 "`host` names the TARGET, not the payer: bin/prod-smoke drives playwright " \
                 "LOCALLY against a production URL, so this box pays in full"
  end

  def test_an_unreadable_scope_row_costs_a_full_suite
    [nil, {}, { "host" => "qa" }, { "tier" => "smoke" }, { "host" => "qa", "tier" => "wat" }].each do |row|
      assert_equal ReleasePresence::WEIGHT_SUITE, ReleasePresence.scope_weight(row),
                   "an unrecognised row (#{row.inspect}) must cost a FULL suite. Over-reporting " \
                   "makes a peer wait for a machine that was free; under-reporting lets it " \
                   "launch into a saturated one, which is cost #3 all over again — the same " \
                   "asymmetry AgentPresence::UNKNOWN_WEIGHT encodes"
    end
  end

  # The registry is the source of truth, so read it and state the whole table. This is a
  # DOCUMENTATION assertion — it would follow the code if both were changed together, which
  # is exactly why the load-bearing weight test is the headroom one in the integration tier.
  def test_every_registered_release_scope_resolves_to_the_weight_its_payer_implies
    scopes = YAML.load_file(File.expand_path("../../config/devops_test_suites.yml", __dir__))
                 .fetch("release_scopes")
    expected = {
      "pre_qa_gate" => "suite",       # local integration tier
      "qa_up_smoke" => "light",       # curl poll, QA dyno boots
      "qa_post_deploy" => "light",    # heroku run, remote
      "ship_test_gate" => "suite",    # the full local suite
      "gem_release_check" => "suite", # syntax + unit + build, local
      "prod_up_smoke" => "light",     # curl poll
      "prod_post_deploy" => "light",  # heroku run, remote
      "prod_smoke_seal" => "suite"    # playwright, driven LOCALLY against prod
    }

    assert_equal expected.keys.sort, scopes.keys.sort,
                 "a scope was added or renamed — give it a row here so its local cost is a " \
                 "decision somebody made rather than a default nobody saw"
    scopes.each do |key, meta|
      assert_equal expected.fetch(key), ReleasePresence.scope_weight(meta),
                   "#{key} (host=#{meta['host']}, tier=#{meta['tier']}) must weigh " \
                   "#{expected.fetch(key)}"
    end
  end

  private

  # A real, live, unrelated process to stand in for a peer conductor. It must be a pid the
  # OS actually knows, or the reader grades it dead and the test proves nothing.
  def spawn_sleeper = Process.spawn("/bin/sleep", "30", out: File::NULL, err: File::NULL)

  def kill_sleeper(pid)
    return if pid.nil?

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
