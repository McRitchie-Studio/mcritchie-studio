require "test_helper"

# Unit — GateRun.append_sop!'s handling of RUNNING lane entries.
#
# The certs emit `running` before a lane and re-emit it every ~40s as a
# heartbeat. Without collapsing, a seven-minute lane would stack ten near-identical
# rows into the gate's sops list and bloat the gates card. Collapsing must be
# surgical: only `running` rows are ever dropped, and only for the same lane.
class GateRunRunningSopTest < ActiveSupport::TestCase
  def append(slug, sop, result, at: Time.current, cmd: "bin/rails test")
    GateRun.append_sop!(subject_type: "task", subject_slug: slug, key: "g1_cert",
                        sop: { "sop" => sop, "cmd" => cmd, "result" => result, "at" => at.iso8601 })
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
end
