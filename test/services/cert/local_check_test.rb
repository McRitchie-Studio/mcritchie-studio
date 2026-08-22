require "test_helper"

# Unit — Cert::LocalCheck turns an in-flight g1_cert GateRun into the three
# things the board card asks: which lane, how long, and IS IT STILL ALIVE.
#
# That third question is the feature. A spinner that cannot die would report
# "working" for exactly the abandoned tasks this exists to expose, so the
# running/stalled boundary gets the most tests here.
class Cert::LocalCheckTest < ActiveSupport::TestCase
  def gate_run(sops: [], started_at: 30.seconds.ago, finished_at: nil, slug: "demo-task")
    GateRun.create!(
      subject_type: "task", subject_slug: slug, key: "g1_cert", attempt: 1,
      started_at: started_at, finished_at: finished_at, sops: sops
    )
  end

  def running_sop(sop: "mapped-tests", at: Time.current, cmd: "bin/rails test test/models/x_test.rb")
    { "sop" => sop, "cmd" => cmd, "result" => "running", "at" => at.iso8601 }
  end

  # --- alive vs abandoned ---

  test "a fresh heartbeat reads as running" do
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(at: 10.seconds.ago)]))

    assert_predicate check, :running?
    assert_not_predicate check, :stalled?
    assert_equal :running, check.state
  end

  test "a heartbeat older than the window reads as stalled" do
    stale = Cert::LocalCheck::STALE_AFTER + 30.seconds
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(at: stale.ago)]))

    assert_predicate check, :stalled?
    assert_equal :stalled, check.state
  end

  test "the stale window tolerates a missed beat without flickering" do
    # The certs beat every ~40s. A single missed beat on a busy machine must NOT
    # flip a healthy run to stalled — that would cry wolf on every loaded laptop.
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(at: 80.seconds.ago)]))

    assert_predicate check, :running?, "two beats' grace is the point of STALE_AFTER"
  end

  test "falls back to the attempt start before the first lane reports" do
    # bin/gate `open` fires before the first lane, so there is a real window with
    # an in-flight run and no sops at all.
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [], started_at: 5.seconds.ago))

    assert_predicate check, :running?
    assert_equal Cert::LocalCheck::FALLBACK_LABEL, check.label
  end

  test "an attempt open with no lane for too long reads as stalled" do
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [], started_at: 10.minutes.ago))

    assert_predicate check, :stalled?, "a cert that never reported a lane is not alive"
  end

  # --- which lane ---

  test "names the running lane in operator language" do
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(sop: "mapped-tests")]))

    assert_equal "Running mapped tests", check.label
    assert_equal "mapped-tests", check.lane
  end

  test "an unmapped lane label falls through to its raw name" do
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(sop: "some-new-lane")]))

    assert_equal "some-new-lane", check.label, "a new lane must still render, never blank"
  end

  test "reports the running lane's command for the tooltip" do
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: [running_sop(cmd: "bin/rubocop app/models/x.rb")]))

    assert_equal "bin/rubocop app/models/x.rb", check.command
  end

  test "picks the running lane, ignoring lanes that already settled" do
    sops = [
      { "sop" => "test-prepare", "result" => "pass", "at" => 90.seconds.ago.iso8601 },
      running_sop(sop: "spine", at: 5.seconds.ago)
    ]
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: sops))

    assert_equal "spine", check.lane, "a settled lane must never be reported as in progress"
    assert_equal "Running core spine", check.label
  end

  test "takes the LAST running entry when several are present" do
    sops = [running_sop(sop: "spine", at: 5.minutes.ago), running_sop(sop: "rubocop-changed", at: 2.seconds.ago)]

    assert_equal "rubocop-changed", Cert::LocalCheck.from_gate_run(gate_run(sops: sops)).lane
  end

  # --- when there is nothing to show ---

  test "a finished attempt yields no check" do
    run = gate_run(sops: [running_sop], finished_at: Time.current)

    assert_nil Cert::LocalCheck.from_gate_run(run),
      "a closed cert is history — the card must drop the indicator"
  end

  test "a nil run yields no check" do
    assert_nil Cert::LocalCheck.from_gate_run(nil)
  end

  # --- the clock ---

  test "elapsed counts from the attempt start, not the last beat" do
    check = Cert::LocalCheck.from_gate_run(gate_run(started_at: 3.minutes.ago, sops: [running_sop]))

    assert_in_delta 180, check.elapsed_seconds, 2, "the operator wants total time in the cert"
  end

  test "elapsed never goes negative on a clock skew" do
    check = Cert::LocalCheck.from_gate_run(gate_run(started_at: 5.seconds.from_now, sops: [running_sop]))

    assert_operator check.elapsed_seconds, :>=, 0
  end

  test "survives an unparseable heartbeat timestamp" do
    sops = [{ "sop" => "spine", "result" => "running", "at" => "not-a-time" }]
    check = Cert::LocalCheck.from_gate_run(gate_run(sops: sops, started_at: 10.seconds.ago))

    assert_nothing_raised { check.stalled? }
    assert_predicate check, :running?, "a bad stamp falls back to the attempt start, not a crash"
  end
end
