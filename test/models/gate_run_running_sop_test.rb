require "test_helper"

# Unit — GateRun.append_sop!'s handling of RUNNING lane entries.
#
# The certs emit `running` before a lane and re-emit it every ~40s as a
# heartbeat. Without collapsing, a seven-minute lane would stack ten near-identical
# rows into the gate's sops list and bloat the gates card. Collapsing must be
# surgical: only `running` rows are ever dropped, and only for the same lane.
#
# AND A BEAT MAY NOT OPEN AN ATTEMPT. Every test here opens the gate first,
# because that is what the certs do (`bin/gate open` before the first lane) and
# because a `running` row that arrives with nothing in flight is a STRAGGLER, not
# a new attempt — see the LATE BEAT block at the bottom for what it cost.
class GateRunRunningSopTest < ActiveSupport::TestCase
  setup do
    GateRun.open!(subject_type: "task", subject_slug: "t1", key: "g1_cert")
  end

  def append(slug, sop, result, at: Time.current, cmd: "bin/rails test")
    GateRun.append_sop!(subject_type: "task", subject_slug: slug, key: "g1_cert",
                        sop: { "sop" => sop, "cmd" => cmd, "result" => result, "at" => at.iso8601 })
  end

  def attempts(slug = "t1")
    GateRun.for_subject("task", slug).where(key: "g1_cert")
  end

  test "a heartbeat replaces the prior running row for the same lane" do
    append("t1", "spine", "running", at: 2.minutes.ago)
    run = append("t1", "spine", "running", at: Time.current)

    running = run.sops.select { |s| s["result"] == "running" }
    assert_equal 1, running.length, "beats must collapse, not stack"
  end

  test "the surviving row carries the LATEST timestamp" do
    append("t1", "spine", "running", at: 5.minutes.ago)
    run = append("t1", "spine", "running", at: 1.second.ago)

    at = Time.zone.parse(run.sops.last["at"])
    assert_operator at, :>, 1.minute.ago, "a stale beat would read as stalled forever"
  end

  test "a terminal verdict clears the lane's running row" do
    append("t1", "spine", "running")
    run = append("t1", "spine", "pass")

    assert_empty run.sops.select { |s| s["result"] == "running" }
    assert_equal %w[pass], run.sops.map { |s| s["result"] }
  end

  test "running rows for DIFFERENT lanes coexist" do
    append("t1", "spine", "running")
    run = append("t1", "rubocop-changed", "running")

    assert_equal 2, run.sops.length, "collapsing must be per-lane, not global"
  end

  test "a real verdict is never dropped by a later lane" do
    append("t1", "test-prepare", "pass")
    append("t1", "spine", "running")
    run = append("t1", "spine", "pass")

    assert_includes run.sops.map { |s| s["sop"] }, "test-prepare",
      "history must survive — only running rows are transient"
  end

  test "two real verdicts for one lane both survive" do
    append("t1", "spine", "fail")
    run = append("t1", "spine", "pass")

    assert_equal %w[fail pass], run.sops.map { |s| s["result"] },
      "a lane that ran twice keeps both outcomes"
  end

  test "an entry with no lane name is appended untouched" do
    append("t1", "spine", "running")
    run = GateRun.append_sop!(subject_type: "task", subject_slug: "t1", key: "g1_cert",
                              sop: { "cmd" => "something", "result" => "pass" })

    assert_equal 2, run.sops.length
  end

  # ── THE LATE BEAT ─────────────────────────────────────────────────────────
  #
  # A beat is a `bin/gate` CHILD PROCESS. Killing the thread that spawned it does
  # not unspawn it, so one can outlive the cert and arrive after the verdict. When
  # `running` still flowed through `open!`, such a straggler did one of two things,
  # both of which the board reported as a cert that never ends:
  #
  #   · after close! — created attempt n+1 carrying a lone `running` row. A
  #     PHANTOM ATTEMPT: Cert::LocalCheckReader reads in-flight attempts, so the
  #     card showed a finished cert as live until STALE_AFTER, then STALLED forever.
  #   · before close! — repainted `running` over a lane that had already settled.
  #
  # CertEmission::Heartbeat#stop orders shutdown so this does not happen on the
  # path we control; these tests are about the paths we do not (SIGKILL above all).

  test "a running beat with NO attempt in flight lands nowhere" do
    GateRun.close!(subject_type: "task", subject_slug: "t1", key: "g1_cert", success: true)

    assert_nil append("t1", "spine", "running"), "a straggler must report that it was dropped"
    assert_equal 1, attempts.count, "a beat must never open attempt n+1"
  end

  test "a running beat after the close does not reopen the closed attempt" do
    append("t1", "spine", "running")
    append("t1", "spine", "pass")
    GateRun.close!(subject_type: "task", subject_slug: "t1", key: "g1_cert", success: true)

    append("t1", "spine", "running")

    run = attempts.sole
    assert_not run.in_flight?, "the verdict stands; a late beat may not revive it"
    assert_equal %w[pass], run.sops.map { |s| s["result"] },
      "the settled lane must not be repainted as running"
  end

  test "a TERMINAL row with no attempt in flight still opens one" do
    GateRun.close!(subject_type: "task", subject_slug: "t1", key: "g1_cert", success: true)

    run = append("t1", "spine", "pass")

    assert_not_nil run, "only beats are dropped — a real verdict is always evidence of an attempt"
    assert_equal 2, attempts.count
  end

  test "a beat still lands while its own attempt is in flight" do
    run = append("t1", "spine", "running")

    assert_not_nil run, "the guard must not cost a LIVE cert its heartbeat"
    assert_equal 1, run.sops.length
    assert run.in_flight?
  end
end
