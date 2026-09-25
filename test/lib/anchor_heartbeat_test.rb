# frozen_string_literal: true

# Tests for bin/lib/anchor_heartbeat.rb — the seam that tells a WORKING agent from a
# merely RESIDENT process.
#
# THE DEFECT, measured 2026-09-22. A `codex --yolo` session (pid 51595) hit a usage
# limit and was shut down. The process stayed in the process table, so
# SessionIdentity.process_alive? kept answering TRUE, so the detached renewer kept
# advancing the lease — observed moving 03:50:45Z → 03:52:47Z across a 75-second
# read — over a desk holding 124 uncommitted lines nobody was coming back for.
#
# A held-but-abandoned desk cannot be reclaimed (the sweep withholds a claimed desk)
# and cannot be taken (no session steals a live claim), so the two safety rules
# compose into a deadlock. That is why an idle anchor must stop renewing.
#
# THE OTHER FACE, measured the same day during a live `bin/release prepare`: no agent
# process resolved at all, so no renewer started, the assembler claim lapsed ~120s
# into a multi-minute act, and the run ended unable to release what it no longer
# held. The remedy there is a HONEST REPORT, never a refusal — that sweep completed
# correctly without a claim, and an act that refused to start on a missing anchor
# would wedge the release lane while fixing nothing.
#
#   ruby -Itest test/lib/anchor_heartbeat_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/anchor_heartbeat"
require_relative "../../bin/lib/session_markers"
require_relative "../../lib/claim_lease"

class AnchorHeartbeatTest < Minitest::Test
  SESSION = "8d632410-aaaa-bbbb-cccc-000000000001"

  # --- The decision, as arithmetic ------------------------------------------

  def test_unit_a_resident_process_whose_session_has_gone_quiet_is_idle
    # THE 2026-09-22 ORPHAN. Residency says yes; the session has left no mark for
    # longer than healthy work is ever measured to go quiet.
    verdict = AnchorHeartbeat.verdict(resident: true,
                                      signal_age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 1)

    assert_equal :idle, verdict
    refute AnchorHeartbeat.holding?(verdict), "an idle anchor must stop renewing its claim"
  end

  def test_unit_a_live_anchor_inside_the_window_keeps_the_claim_held
    verdict = AnchorHeartbeat.verdict(resident: true, signal_age: 30)

    assert_equal :working, verdict
    assert AnchorHeartbeat.holding?(verdict), "a working anchor must keep its claim"
  end

  def test_unit_a_dead_anchor_is_gone_whatever_the_signal_says
    # Residency is decisive on its own, and must stay decisive: a stale signal is not
    # required to conclude a process that no longer exists is gone.
    assert_equal :gone, AnchorHeartbeat.verdict(resident: false, signal_age: 0)
    assert_equal :gone, AnchorHeartbeat.verdict(resident: false, signal_age: nil)
    refute AnchorHeartbeat.holding?(:gone)
  end

  def test_unit_no_signal_at_all_holds_the_claim_rather_than_freeing_it
    # THE ASYMMETRY THIS FILE TURNS ON. nil is "we could not look", not "it has been
    # quiet for ages". Only a POSITIVE reading may cost a holder its lease, because
    # this seam now sits in front of the production release claim.
    verdict = AnchorHeartbeat.verdict(resident: true, signal_age: nil)

    assert_equal :unverified, verdict
    assert AnchorHeartbeat.holding?(verdict), "no evidence must never free a claim"
  end

  def test_unit_the_boundary_second_still_counts_as_working
    # Exactly AT the bound is not yet past it — the comparison is `>`, so a signal
    # landing on the threshold keeps the claim. Pinned because flipping it to `>=`
    # is a silent one-beat-early eviction.
    on_bound = AnchorHeartbeat.verdict(resident: true, signal_age: AnchorHeartbeat::IDLE_AFTER_SECONDS)

    assert_equal :working, on_bound
  end

  def test_unit_only_gone_and_idle_stop_a_renewal
    assert_equal %i[gone idle].sort, AnchorHeartbeat::STOPS_RENEWING.sort
    %i[working unverified].each do |verdict|
      assert AnchorHeartbeat.holding?(verdict), "#{verdict} must not stop a renewal"
    end
  end

  def test_unit_the_idle_bound_is_the_houses_derived_quiet_ceiling_not_a_new_number
    # BORROWED, NOT INVENTED. Re-measure ClaimLease's corpus and this moves with it;
    # a literal here would be a second threshold to argue about. (The comment this
    # replaced also claimed the two answer the SAME question. They do not — see
    # test_unit_the_idle_bound_is_the_looser_of_two_borrowed_bounds. The assertion
    # was right and is kept; only its reason was wrong.)
    assert_equal ClaimLease::PROGRESS_QUIET_SECONDS, AnchorHeartbeat::IDLE_AFTER_SECONDS
  end

  # --- the narration corpus, and what it says about the bound ---------------
  #
  # THE DEFECT THESE PIN was an ARGUMENT, not a number. IDLE_AFTER_SECONDS reused
  # PROGRESS_QUIET_SECONDS on the claim that narration markers are "durable
  # artifacts of exactly that kind". lib/claim_lease.rb ENUMERATES that kind — a
  # TaskEvent or a GateRun — and Task#progress_evidence reads exactly those two
  # associations. Narration writes agent_activity rows and marker files, so the
  # 243 windows of BOARD silence behind that constant are a different population.
  #
  # The number survived the correction; the reasoning did not. These assert the
  # reasoning that replaced it, so a future reader cannot restore the population
  # match without reddening something.

  def test_unit_the_narration_corpus_derives_the_bound_it_states
    # "A number in prose cannot be checked. A number in a constant can."
    # (lib/claim_lease.rb, about its own two corpora.)
    corpus = AnchorHeartbeat::MEASURED_NARRATION_GAP_SECONDS

    assert_equal (corpus[:working_max] * AnchorHeartbeat::NARRATION_IDLE_SAFETY_FACTOR).ceil,
                 AnchorHeartbeat::NARRATION_QUIET_SECONDS
    assert_equal 5_391, AnchorHeartbeat::NARRATION_QUIET_SECONDS
  end

  def test_unit_the_narration_corpus_bands_do_not_overlap
    # The x1.5 derivation is only meaningful if the working band and the away band
    # are actually separable — the same lemma MEASURED_DESK_GAP_SECONDS rests on.
    # Narration's gutter is 70s against the desk corpus's 339s, which is why the
    # header calls the split SOFT and declines to lean on it.
    corpus = AnchorHeartbeat::MEASURED_NARRATION_GAP_SECONDS

    assert_operator corpus[:abandoned_min], :>, corpus[:working_max],
                    "a negative gutter would mean the bands overlap and the derivation is void"
    assert_equal 70, corpus[:abandoned_min] - corpus[:working_max]
  end

  # THE GUARD THAT MATTERS. Two borrowed bounds were available and the LOOSER was
  # taken deliberately, under the asymmetry that this file can only ever STOP a
  # renewal and one of the lanes behind it is the production deploy path. A later
  # "repair" that population-matches would TIGHTEN the bound by 2.09x and reads as
  # a correction; it reddens here instead.
  def test_unit_the_idle_bound_is_the_looser_of_two_borrowed_bounds
    assert_operator AnchorHeartbeat::IDLE_AFTER_SECONDS, :>,
                    AnchorHeartbeat::NARRATION_QUIET_SECONDS,
                    "tightening to the population match trades a false STOP for a false HOLD — " \
                    "restate the header's asymmetry argument before changing this"
  end

  def test_unit_the_bound_clears_every_measured_healthy_narration_gap
    # The quietest WORKING session in a 3,112-gap corpus went 59.9 minutes. Whatever
    # else is argued about the bound, it must not bite healthy narration.
    assert_operator AnchorHeartbeat::MEASURED_NARRATION_GAP_SECONDS[:working_max], :<,
                    AnchorHeartbeat::IDLE_AFTER_SECONDS
  end

  # THE HEADER'S HONESTY CLAIM, as arithmetic. The seam BOUNDS the 2026-09-22
  # orphan; it does not catch it at the moment of observation. Measured from the
  # live store: the incident session's newest counting marker sat at 20:22:09 MDT
  # and the orphan was observed at 21:52:47 MDT, so signal_age was 5,438s.
  #
  # If a future change makes this red, the header is now wrong too — move both.
  def test_unit_the_seam_bounds_the_measured_orphan_rather_than_catching_it
    observed_signal_age = 5_438

    assert_equal :working,
                 AnchorHeartbeat.verdict(resident: true, signal_age: observed_signal_age),
                 "at the moment of observation the renewer WOULD have renewed — say so in the header"
    assert_equal :idle,
                 AnchorHeartbeat.verdict(resident: true,
                                         signal_age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 1),
                 "and it does eventually bite, ~97 minutes later"
  end

  # --- The lambda the lanes actually pass to ShiftRenewer -------------------

  def test_unit_the_alive_check_stops_a_resident_but_idle_anchor
    check = AnchorHeartbeat.alive_check(resident: -> { true },
                                        signal: -> { AnchorHeartbeat::IDLE_AFTER_SECONDS + 60 })

    refute check.call, "the seam must stop renewing for a resident-but-idle anchor"
  end

  def test_unit_the_alive_check_keeps_a_resident_and_active_anchor
    check = AnchorHeartbeat.alive_check(resident: -> { true }, signal: -> { 10 })

    assert check.call
  end

  def test_unit_the_alive_check_never_consults_the_signal_for_a_dead_anchor
    # The residency answer is decisive and CHEAP; asking the disk about a process we
    # already know is gone is pure cost on the one path that runs every beat.
    asked = false
    check = AnchorHeartbeat.alive_check(resident: -> { false }, signal: -> { asked = true; 0 })

    refute check.call
    refute asked, "a dead anchor must short-circuit before the liveness read"
  end

  def test_unit_a_signal_read_that_raises_leaves_the_pre_existing_behaviour
    # ShiftRenewer does NOT rescue alive.call. An exception escaping here would kill
    # the renewer outright and drop a LIVE holder's lease — strictly worse than the
    # defect being fixed — so the seam degrades to the residency answer alone.
    check = AnchorHeartbeat.alive_check(resident: -> { true }, signal: -> { raise "store on fire" })

    assert check.call, "a failed liveness read must not cost a resident holder its claim"
  end

  # --- The signal itself, over a real marker store ---------------------------

  def test_integration_a_fresh_narration_marker_reads_as_a_working_session
    with_store do |dir|
      write_marker(dir, ".open-activity", age: 20)

      age = AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)

      refute_nil age
      assert_operator age, :<, 120
      assert_equal :working, AnchorHeartbeat.verdict(resident: true, signal_age: age)
    end
  end

  def test_integration_a_session_whose_markers_have_gone_stale_reads_as_idle
    with_store do |dir|
      write_marker(dir, ".open-activity", age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 600)
      write_marker(dir, ".acting-agent", age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 900)

      age = AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)

      assert_operator age, :>, AnchorHeartbeat::IDLE_AFTER_SECONDS
      assert_equal :idle, AnchorHeartbeat.verdict(resident: true, signal_age: age)
    end
  end

  def test_integration_the_newest_marker_wins_so_any_one_channel_vouches
    with_store do |dir|
      write_marker(dir, ".acting-agent", age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 900)
      write_marker(dir, ".open-activity", age: 45)

      age = AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)

      assert_operator age, :<, 120, "the freshest mark is the one that proves life"
    end
  end

  def test_integration_a_statusline_throttle_alone_never_vouches_for_an_agent
    # THE LOAD-BEARING EXCLUSION. bin/statusline writes .heartbeat whenever Claude
    # Code PAINTS, and this machine carries `claude` processes open for days. Counting
    # it would let an OPEN TERMINAL behind a dead agent renew forever — the 2026-08-13
    # immortal lease, rebuilt. lib/claim_lease.rb already settled it: "A heartbeat
    # proves a TERMINAL IS OPEN. Nothing more."
    with_store do |dir|
      write_marker(dir, ".heartbeat", age: 1)
      write_marker(dir, ".shift-heartbeat", age: 1)
      write_marker(dir, ".mascot-heal", age: 1)

      assert_nil AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir),
                 "terminal throttles must not read as agent liveness"
    end
  end

  def test_integration_a_fresh_throttle_cannot_rescue_a_stale_session
    # The composed statement of the test above: the throttle is not merely ignored in
    # isolation, it cannot OUTVOTE a stale real marker. This is the shape the defect
    # would actually take in production — a dead agent in a terminal still painting.
    with_store do |dir|
      write_marker(dir, ".open-activity", age: AnchorHeartbeat::IDLE_AFTER_SECONDS + 600)
      write_marker(dir, ".heartbeat", age: 1)

      age = AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)

      assert_equal :idle, AnchorHeartbeat.verdict(resident: true, signal_age: age),
                   "a painting terminal must not vouch for the agent behind it"
    end
  end

  def test_integration_an_empty_or_missing_store_is_unknown_not_quiet
    with_store do |dir|
      assert_nil AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)
    end
    assert_nil AnchorHeartbeat.signal_age(session: SESSION, projects_dir: "/nonexistent/projects/root")
  end

  def test_integration_another_sessions_markers_never_vouch_for_this_one
    # The store is shared by every session on the machine. A signal keyed on the
    # DIRECTORY rather than on the session would make one busy agent renew every
    # other agent's abandoned claims.
    with_store do |dir|
      write_marker(dir, ".open-activity", age: 5, session: "99999999-dead-dead-dead-999999999999")

      assert_nil AnchorHeartbeat.signal_age(session: SESSION, projects_dir: dir)
    end
  end

  def test_unit_a_blank_session_is_unknown_rather_than_an_error
    assert_nil AnchorHeartbeat.signal_age(session: "", projects_dir: "/tmp")
    assert_nil AnchorHeartbeat.signal_age(session: nil, projects_dir: "/tmp")
  end

  # --- Face two: no anchor at all -------------------------------------------

  def test_unit_the_unanchored_notice_states_that_nothing_will_renew_it
    # THE OLD WORDING NAMED A CONDITION THAT WAS ALREADY DECIDED — "lapses in ~120s
    # unless something renews it" — and printed immediately above the "✅ claimed"
    # line, so the only warning the operator got read as a footnote to a success.
    notice = AnchorHeartbeat.unanchored_notice(subject: "assembler claim", ttl_seconds: 120)

    assert_match(/NOTHING will renew this assembler claim/, notice)
    assert_match(/UNPROTECTED/, notice)
    refute_match(/unless something renews it/, notice)
  end

  def test_unit_the_unanchored_notice_says_the_run_continues
    # NOT A REFUSAL, and this is the constraint worth pinning. The observed
    # `bin/release prepare` COMPLETED CORRECTLY with no live claim — the claim is a
    # collision guard, not a correctness precondition — so an act that refused to
    # start on a missing anchor would wedge the release lane while fixing nothing.
    notice = AnchorHeartbeat.unanchored_notice(subject: "shift", ttl_seconds: 120)

    assert_match(/Continuing anyway/, notice)
    assert_match(/not required for this run to be correct/, notice)
  end

  # --- The seam must STAY a seam --------------------------------------------

  def test_unit_every_renewing_lane_asks_the_seam_and_not_the_bare_process_probe
    # THE REGRESSION THIS GUARDS. The build lane's abandonment gate landed at a CALL
    # SITE in 2026-09-09 and the seam stayed unchanged, so the next three lanes were
    # written against the old `alive: -> { SessionIdentity.process_alive?(...) }` and
    # inherited the defect. A fifth lane copied from any of them would do it again.
    root = File.expand_path("../..", __dir__)
    lanes = {
      "bin/lib/review_claim_cli.rb" => "the REVIEW claim",
      "bin/lib/release_claim_cli.rb" => "the RELEASE conductor claim",
      "bin/devops-shift" => "the DEVOPS SHIFT lease"
    }

    lanes.each do |path, what|
      source = File.read(File.join(root, path))
      # Report the OFFENDING LINE, not the file. A refute_match against a 700-line
      # script prints the whole script on failure, which buries the one fact the
      # reader needs — and a guard whose failure is unreadable gets muted, not fixed.
      offenders = source.lines.each_with_index
                        .select { |line, _| line.match?(/alive:\s*->\s*\{\s*SessionIdentity\.process_alive\?/) }
                        .map { |line, i| "#{path}:#{i + 1}: #{line.strip}" }

      assert_empty offenders,
                   "#{what} passes the bare residency probe as its `alive:` — a resident " \
                   "process is not a working one (the 2026-09-22 orphan). Go through " \
                   "AnchorHeartbeat.alive_check:\n  #{offenders.join("\n  ")}"
      assert_includes source, "AnchorHeartbeat.alive_check",
                      "#{path} (#{what}) must answer liveness through the shared seam"
    end
  end

  private

  def with_store
    Dir.mktmpdir("anchor-heartbeat") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents", "sessions"))
      yield dir
    end
  end

  # Writes a marker into the store with a controlled mtime, through the same path
  # shape SessionMarkers builds (a test may reach the private builder deliberately).
  def write_marker(dir, suffix, age:, session: SESSION)
    path = SessionMarkers.send(:marker_path, session, dir, suffix)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x\n")
    stamp = Time.now - age
    File.utime(stamp, stamp, path)
    path
  end
end
