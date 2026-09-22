# frozen_string_literal: true

# [unit] bin/lib/review_worker_pulse.rb — the WORKER-level half of "is this review
# still being done", and the seam that tells a live reviewer from a dead one inside a
# session that is alive either way.
#
# ═══ THE DEFECT, MEASURED TWICE ON 2026-09-22 ═══
#
# A harness watchdog ("no progress for 600s") killed reviewer subagents in two separate
# events about four hours apart. Both times the dead reviewer's claim immediately read
# RENEWING with a seconds-fresh heartbeat under the CONDUCTOR'S session — because the
# conductor kept working, so the anchor stayed alive, so the detached renewer went on
# renewing a claim for a worker that no longer existed.
#
# AnchorHeartbeat cannot reach this. It answers :working when the SESSION narrated
# inside PROGRESS_QUIET_SECONDS, which here is a TRUE POSITIVE about the session and
# says nothing whatever about the worker. Its two designed faces are "no anchor at all"
# and "a dead anchor still resident"; this is neither.
#
# ═══ WHY THE FIX IS A SIGNAL AND NOT AN IDENTITY ═══
#
# The obvious design — record the SUBAGENT identity so liveness can ask about the
# worker — was measured first and is NOT IMPLEMENTABLE. Running one probe from a parent
# agent and the same probe from a subagent of it, same machine, seconds apart, every
# identity-bearing fact was byte-identical: CLAUDE_CODE_SESSION_ID, CLAUDE_PID, the
# shell's ppid (both the same `claude` process), SessionIdentity.nonce, and
# SessionIdentity.agent_process. A subagent is not an OS process and carries nothing of
# its own. There is nothing to record.
#
# What is actually missing is a SIGNAL. A review claim is touched in the FOREGROUND
# exactly once in its life — the `acquire` — and everything after it is the detached
# renewer. So the claim carries no worker-produced evidence at all, and the two states
# are indistinguishable because there is nothing to distinguish them WITH. A signal can
# be created where an identity cannot.
#
#   ruby -Itest test/lib/review_worker_pulse_test.rb

require "minitest/autorun"
require "json"
require "time"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../support/session_env"
require_relative "../../bin/lib/review_worker_pulse"
require_relative "../../bin/lib/session_markers"
require_relative "../../lib/claim_lease"

load File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__)

class ReviewWorkerPulseTest < Minitest::Test
  SLUG = "widen-detector-two-name-lookup"
  # The CONDUCTOR'S session — the one that was alive and narrating through both
  # incidents while the reviewer subagent inside it was gone.
  SESSION = "1c7e1097-897a-4095-be17-83552622debe"
  OTHER_SESSION = "7c21d0aa-15be-4f0d-9a33-0b6e12c4d9c1"
  START = Time.parse("2026-09-22T04:14:28Z")

  # ── The decision, as arithmetic ────────────────────────────────────────────

  def test_unit_a_claim_with_no_foreground_touch_past_the_bound_is_silent
    verdict = ReviewWorkerPulse.verdict(pulse_age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 1)

    assert_equal :silent, verdict
    refute ReviewWorkerPulse.holding?(verdict), "a silent worker must stop renewing its claim"
  end

  def test_unit_a_recent_foreground_touch_keeps_the_claim
    verdict = ReviewWorkerPulse.verdict(pulse_age: 30)

    assert_equal :active, verdict
    assert ReviewWorkerPulse.holding?(verdict)
  end

  def test_unit_no_pulse_at_all_holds_the_claim_rather_than_freeing_it
    # The same asymmetry AnchorHeartbeat turns on: nil is "we could not look", never
    # "nobody has touched it in ages". Only a POSITIVE reading may cost a lease.
    verdict = ReviewWorkerPulse.verdict(pulse_age: nil)

    assert_equal :unverified, verdict
    assert ReviewWorkerPulse.holding?(verdict), "no evidence must never free a claim"
  end

  def test_unit_the_boundary_second_still_counts_as_active
    # `>` not `>=` — a pulse landing exactly on the threshold keeps the claim.
    on_bound = ReviewWorkerPulse.verdict(pulse_age: ReviewWorkerPulse::SILENT_AFTER_SECONDS)

    assert_equal :active, on_bound
  end

  def test_unit_only_silent_stops_a_renewal
    assert_equal %i[silent], ReviewWorkerPulse::STOPS_RENEWING.to_a
    %i[active unverified].each do |verdict|
      assert ReviewWorkerPulse.holding?(verdict), "#{verdict} must not stop a renewal"
    end
  end

  def test_unit_the_silent_bound_is_the_lanes_derived_ceiling_not_a_new_number
    # DERIVED, NOT CHOSEN — the same constant the renewer's existing cap uses, so
    # re-measuring the review corpus moves both together. A literal here would be a
    # second threshold to argue about.
    assert_equal ClaimLease::REVIEW_TTL_SECONDS, ReviewWorkerPulse::SILENT_AFTER_SECONDS
    assert_equal ReviewClaimCli::REVIEW_RENEW_WINDOW_SECONDS, ReviewWorkerPulse::SILENT_AFTER_SECONDS
  end

  # ── Whose claim is it ──────────────────────────────────────────────────────

  def test_unit_the_holder_being_this_session_is_recognised
    assert ReviewWorkerPulse.mine?(holder_session: SESSION, session: SESSION)
    refute ReviewWorkerPulse.mine?(holder_session: OTHER_SESSION, session: SESSION)
  end

  def test_unit_a_blank_session_on_either_side_is_never_a_match
    # Two unidentifiable callers are not the same caller. Matching "" to "" would
    # hand every session the release advice for every claim it cannot identify.
    refute ReviewWorkerPulse.mine?(holder_session: "", session: "")
    refute ReviewWorkerPulse.mine?(holder_session: SESSION, session: "  ")
    refute ReviewWorkerPulse.mine?(holder_session: nil, session: SESSION)
  end

  # ── The alive: lambda the renew-loop passes ────────────────────────────────

  def test_unit_the_alive_check_stops_a_claim_whose_worker_has_gone_silent
    check = ReviewWorkerPulse.alive_check(pulse: -> { ReviewWorkerPulse::SILENT_AFTER_SECONDS + 60 })

    refute check.call
  end

  def test_unit_the_alive_check_keeps_a_claim_whose_worker_is_beating
    assert ReviewWorkerPulse.alive_check(pulse: -> { 10 }).call
  end

  def test_unit_a_pulse_read_that_raises_leaves_the_claim_held
    # ShiftRenewer does not rescue alive.call: an exception escaping here would kill
    # the renewer outright and drop a LIVE reviewer's lease — strictly worse than the
    # defect being fixed.
    check = ReviewWorkerPulse.alive_check(pulse: -> { raise "store on fire" })

    assert check.call, "a failed pulse read must not cost a holder its claim"
  end

  # ── The pulse over a real marker store ─────────────────────────────────────

  def test_integration_a_fresh_foreground_touch_reads_as_an_active_worker
    with_store do |dir|
      # The guarded write seam needs its destination PINNED under the sandbox — an
      # unpinned marker write is refused rather than falling back to the operator's
      # real store (test/support/task_usage_sandbox.rb).
      ReviewWorkerPulse.touch(session: SESSION, projects_dir: dir, slug: SLUG,
                              env: { "CLAUDE_PROJECTS_DIR" => dir })

      age = ReviewWorkerPulse.pulse_age(session: SESSION, projects_dir: dir, slug: SLUG)

      refute_nil age
      assert_operator age, :<, 120
      assert_equal :active, ReviewWorkerPulse.verdict(pulse_age: age)
    end
  end

  def test_integration_a_stale_claim_marker_reads_as_a_silent_worker
    with_store do |dir|
      stamp_pulse(dir, age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 600)

      age = ReviewWorkerPulse.pulse_age(session: SESSION, projects_dir: dir, slug: SLUG)

      assert_equal :silent, ReviewWorkerPulse.verdict(pulse_age: age)
    end
  end

  def test_integration_a_store_with_no_marker_for_this_slug_answers_unverified
    with_store do |dir|
      # A marker for a DIFFERENT task in the same session must not vouch for this one.
      # This is the whole reason touched_at exists beside last_signal_at: one session
      # holds many claims, and the session-wide signal cannot separate them.
      stamp_pulse(dir, age: 5, slug: "some-other-review")

      assert_nil ReviewWorkerPulse.pulse_age(session: SESSION, projects_dir: dir, slug: SLUG)
    end
  end

  def test_integration_another_sessions_claim_is_unverifiable_here
    with_store do |dir|
      stamp_pulse(dir, age: 5, session: OTHER_SESSION)

      assert_nil ReviewWorkerPulse.pulse_age(session: SESSION, projects_dir: dir, slug: SLUG),
                 "the marker is written by the instance that acquired the claim, so a " \
                 "foreign claim leaves no local evidence — and must answer UNKNOWN " \
                 "rather than borrowing another session's"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # THE CONTROLS — the two states, and the assertion that `status` tells them apart
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # THE EXACT READING FROM THE INCIDENT, and why a shorter TTL is not the fix. When
  # the first dead reviewer RESUMED and re-acquired his claim, `review-claim status`
  # printed a reading identical to the one it gave while he was dead — RENEWING, same
  # holder, ~2s heartbeat. In his words: "nothing in that command's output could have
  # told you which you had."
  #
  # So these two controls drive the REAL `status` path with a board that behaves
  # IDENTICALLY in both — same holder, same session, same moving expiry — and differ in
  # exactly one fact: whether a foreground command has touched the review. The lease
  # half of the output must be identical (that is the defect, and it is not being
  # papered over); the worker half must differ (that is the fix).

  def test_control_a_live_worker_under_a_live_session_reads_as_active
    out = status_with_pulse(age: 12)

    assert_includes out, "RENEWING", "the lease half is the same in both controls"
    assert_includes out, "worker: ACTIVE",
                    "a foreground command touched this review 12s ago — a dead subagent " \
                    "cannot make a tool call, so this is the one thing it could not have done"
    refute_includes out, "worker: SILENT"
  end

  def test_control_a_dead_worker_under_a_live_session_reads_as_silent
    out = status_with_pulse(age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 3600)

    assert_includes out, "RENEWING",
                    "the lease reads exactly as it did in the live control — this is the " \
                    "defect reproduced, not avoided"
    assert_includes out, "worker: SILENT"
    assert_includes out, "Only the detached renewer",
                    "and it must name WHAT is keeping the claim alive, because that is the " \
                    "fact the reader needs and the lease line cannot carry"
  end

  # THE CONTROL PAIR, asserted as a pair. Each test above passes on its own if the
  # worker line were hard-coded to its own answer; only the comparison proves the
  # output actually TRACKS the worker.
  def test_control_the_two_states_print_the_same_lease_and_a_different_worker
    live = status_with_pulse(age: 12)
    dead = status_with_pulse(age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 3600)

    assert_equal lease_line(live), lease_line(dead),
                 "the LEASE is indistinguishable between a live reviewer and a dead one — " \
                 "that is the measured defect, and the fix must not pretend otherwise"
    refute_equal worker_line(live), worker_line(dead),
                 "and the WORKER line is the whole point: if these agree, `status` still " \
                 "cannot tell the two states apart and nothing has been fixed"

    # AND THE VERDICT, not merely the rendered age. Measured while mutating this file:
    # a `verdict` that stopped reading the pulse age entirely still printed two
    # DIFFERENT worker lines here — "…acted on this review 12s ago" against "…4.4h
    # ago" — so the refute_equal above survived a mutant that had removed the whole
    # decision. Differing text is not a differing verdict, and it is the verdict that
    # the renewer and the remedy line both branch on.
    assert_includes worker_line(live), "ACTIVE"
    assert_includes worker_line(dead), "SILENT"
  end

  # THE MISDIRECTION, as its own control. "ASK THE HOLDER TO RELEASE IT (only their
  # session can)" is addressed to somebody else — and in both incidents the holder WAS
  # the asking session, so the one party able to act was sent away.
  def test_control_a_claim_held_by_this_session_is_never_told_to_ask_the_holder
    out = status_with_pulse(age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 3600)

    refute_includes out, "ASK THE HOLDER TO RELEASE IT",
                    "the holder IS this session; telling it to go and ask is the guidance " \
                    "that cost the conductor the diagnosis twice in one night"
    assert_includes out, "THIS CLAIM IS YOURS"
    assert_includes out, "bin/task review-claim release #{SLUG}",
                    "and the remedy the asking session can actually run must follow the state"
  end

  # The other direction, so the fix cannot buy clarity by breaking the case that was
  # already right: a claim held by ANOTHER session still routes to ASK, and says
  # nothing about a worker it has no evidence about.
  def test_control_another_sessions_claim_keeps_the_ask_the_holder_route
    out = status_with_pulse(age: 12, holder_session: OTHER_SESSION)

    assert_includes out, "ASK THE HOLDER TO RELEASE IT",
                    "there really is somebody else to ask, and that wording is correct there"
    refute_includes out, "worker:",
                    "this session has no local evidence about a foreign claim, so it must " \
                    "say nothing rather than print an unverifiable line on every read"
    refute_includes out, "THIS CLAIM IS YOURS"
  end

  # A FREE lease has no worker to attribute, and the acquire is the whole answer.
  def test_control_a_free_lease_says_nothing_about_a_worker
    out = status_with_pulse(age: 12, lease_seconds: -122)

    assert_includes out, "FREE"
    refute_includes out, "worker:"
  end

  # The MACHINE face of the same distinction, because a caller branches on this
  # rather than on the prose.
  def test_control_the_json_face_carries_the_worker_verdict
    live = JSON.parse(status_with_pulse(age: 12, flags: ["--json"]))
    dead = JSON.parse(status_with_pulse(age: ReviewWorkerPulse::SILENT_AFTER_SECONDS + 3600,
                                        flags: ["--json"]))

    assert_equal true, live["worker"]["held_by_this_session"]
    assert_equal "active", live["worker"]["verdict"]
    assert_equal "silent", dead["worker"]["verdict"]
    assert_equal live["observed"], dead["observed"],
                 "same lease grade, different worker verdict — the machine face must make " \
                 "the same distinction the text does"
  end

  private

  # Drive the REAL `status` against a board that is IDENTICAL across the controls,
  # varying only the age of the foreground pulse.
  #
  # The renewer is beating in every call (the expiry MOVES between the two reads), so
  # the lease grades RENEWING exactly as it did in both measured incidents.
  def status_with_pulse(age:, holder_session: SESSION, lease_seconds: 60, flags: [])
    with_store do |dir|
      stamp_pulse(dir, age: age, session: holder_session)
      out = StringIO.new
      cli = ReviewClaimCli.new(env: { "TASK_REVIEW_CLAIM_SESSION" => SESSION },
                               out: out, err: StringIO.new)
      holders = if lease_seconds.negative?
                  [holder(lease_seconds, holder_session)]
                else
                  [holder(lease_seconds, holder_session), holder(lease_seconds + 30, holder_session)]
                end
      now = START
      cli.instance_variable_set(:@api, ScriptedApi.new(holders, dir))
      cli.instance_variable_set(:@sleeper, ->(seconds) { now += seconds })
      cli.instance_variable_set(:@clock, -> { now })
      cli.run(["status", SLUG, *flags])
      out.string
    end
  end

  def holder(seconds_left, session)
    {
      "task_slug" => SLUG, "session" => session, "label" => "sudowoodo", "agent" => "alex",
      "acquired_at" => (START - 300).utc.iso8601,
      "expires_at" => (START + seconds_left).utc.iso8601,
      "heartbeat_age" => 2, "live" => seconds_left.positive?
    }
  end

  # The board, scripted to MOVE its expiry so the lease grades RENEWING — the reading
  # both incidents produced. `projects_dir` is the test's own store.
  class ScriptedApi
    Resp = Struct.new(:code, :body)

    def initialize(holders, dir)
      @holders = holders
      @dir = dir
      @reads = 0
    end

    def token = "tok"
    def projects_dir = @dir
    def env = {}
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(_method, _path, _body = nil, **)
      holder = @holders[[@reads, @holders.length - 1].min]
      @reads += 1
      Resp.new(200, JSON.generate({ data: { holder: holder } }))
    end
  end

  def lease_line(out)  = out.lines.find { |line| line.start_with?("review-claim:") }.to_s
  def worker_line(out) = out.lines.find { |line| line.strip.start_with?("worker:") }.to_s

  def with_store(&block)
    Dir.mktmpdir("review-worker-pulse") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".agents", "sessions"))
      block.call(dir)
    end
  end

  # Write the claim marker with a controlled mtime — the pulse, as a foreground
  # command would have left it `age` seconds ago. Reaches the private path builder
  # deliberately, as anchor_heartbeat_test.rb does, because a test may.
  def stamp_pulse(dir, age:, session: SESSION, slug: SLUG)
    path = SessionMarkers.send(:marker_path, session, dir, ReviewWorkerPulse.marker_suffix(slug))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{slug}\n")
    stamp = START - age
    File.utime(stamp, stamp, path)
    path
  end
end
