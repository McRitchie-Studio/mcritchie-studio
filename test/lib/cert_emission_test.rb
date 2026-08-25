# frozen_string_literal: true

# Tests for bin/lib/cert_emission.rb — the best-effort G1 durable-record emits
# shared by bin/fast-check and bin/full-suite-check (gate markers, cert
# checkpoint, checks_run read). Fire-and-forget contract: a broken/missing
# binary degrades silently and never raises.
#   ruby -Itest test/lib/cert_emission_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

require File.expand_path("../../bin/lib/cert_emission", __dir__)

class CertEmissionTest < Minitest::Test
  # ── [unit] emit_gate / emit_gate_sop ─────────────────────────────────────────

  def test_unit_emit_gate_shells_the_gate_bin_with_the_args
    with_logging_stub do |stub, log|
      CertEmission.emit_gate(stub, "my-task", "open", "task", "my-task", "g1_cert")
      assert_equal ["open", "task", "my-task", "g1_cert"], logged_argv(log)
    end
  end

  def test_unit_emit_gate_noops_without_a_slug
    with_logging_stub do |stub, log|
      CertEmission.emit_gate(stub, nil, "open")
      CertEmission.emit_gate(stub, "   ", "open")
      refute File.exist?(log), "--print runs (no slug) must write nothing durable"
    end
  end

  def test_unit_emit_gate_sop_records_the_lane_verdict
    with_logging_stub do |stub, log|
      CertEmission.emit_gate_sop(stub, "my-task", "spine", "bin/rails test x", false, 1234)
      argv = logged_argv(log)
      assert_equal ["sop", "task", "my-task", "g1_cert"], argv.first(4)
      assert_includes argv, "--result"
      assert_equal "fail", argv[argv.index("--result") + 1]
      assert_equal "1234", argv[argv.index("--duration-ms") + 1]
    end
  end

  def test_unit_emit_gate_swallows_a_missing_binary
    assert_nil CertEmission.emit_gate("/nonexistent/gate-#{rand(10_000)}", "t", "open"),
               "a gate blip never breaks a cert"
  end

  # ── [unit] emit_cert_checkpoint ──────────────────────────────────────────────

  def test_unit_cert_checkpoint_shells_the_task_bin
    with_logging_stub do |stub, log|
      CertEmission.emit_cert_checkpoint(stub, "my-task", "started")
      assert_equal ["checkpoint", "my-task", "cert", "--status", "started"], logged_argv(log)
    end
  end

  def test_unit_cert_checkpoint_noops_without_a_slug
    with_logging_stub do |stub, log|
      CertEmission.emit_cert_checkpoint(stub, "", "started")
      refute File.exist?(log)
    end
  end

  # ── [unit] fetch_checks ──────────────────────────────────────────────────────

  def test_unit_fetch_checks_reads_the_tasks_checks_run
    payload = JSON.generate("metadata" => { "devops" => { "checks_run" => ["[unit] x"] } })
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_equal ["[unit] x"], CertEmission.fetch_checks(stub, "my-task")
    end
  end

  def test_unit_fetch_checks_is_empty_array_when_the_task_has_none
    payload = JSON.generate("metadata" => { "devops" => { "kind" => "bug" } })
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_equal [], CertEmission.fetch_checks(stub, "my-task"),
                   "[] = a task that HAS devops but no checks yet — distinct from nil (couldn't read)"
    end
  end

  def test_unit_fetch_checks_is_nil_on_failure_or_bad_json
    with_stub_bin("exit 1") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"), "a red bin/task show = unverifiable, abort"
    end
    with_stub_bin("printf '%s' '{nope'") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"), "unparseable output = unverifiable, abort"
    end
  end

  # "I did not find the shape I was looking for" must not read as "there is
  # nothing there". A record with no devops used to yield [], which both certs
  # report as "no pre-existing checks lines to preserve" — a definite, reassuring
  # verdict derived from absence, and the same degrade-open defect this gate
  # exists to kill.
  def test_unit_fetch_checks_is_nil_when_the_record_has_no_devops
    with_stub_bin("printf '%s' '{}'") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"),
                 "a record with no devops is UNREAD, not empty"
    end
    payload = JSON.generate("metadata" => {})
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"), "metadata without devops is UNREAD too"
    end
  end

  def test_unit_missing_after_write_counts_duplicates_not_membership
    payload = JSON.generate("metadata" => { "devops" => { "checks_run" => ["[unit] dupe"] } })
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_equal ["[unit] dupe"],
                   CertEmission.missing_after_write(stub, "my-task", ["[unit] dupe", "[unit] dupe"]),
                   "one of two copies survived — that is still a line the builder recorded and lost"
    end
  end

  # ── [unit] missing_after_write — the read-back behind the "preserved" claim ──

  def test_unit_missing_after_write_names_the_lines_the_board_lost
    payload = JSON.generate("metadata" => { "devops" => { "checks_run" => ["[unit] kept"] } })
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_equal ["[integration] lost"],
                   CertEmission.missing_after_write(stub, "my-task", ["[unit] kept", "[integration] lost"])
    end
  end

  def test_unit_missing_after_write_is_empty_when_everything_persisted
    payload = JSON.generate("metadata" => { "devops" => { "checks_run" => ["[unit] a", "[integration] b"] } })
    with_stub_bin("printf '%s' #{payload.inspect}") do |stub|
      assert_equal [], CertEmission.missing_after_write(stub, "my-task", ["[unit] a"])
    end
  end

  def test_unit_missing_after_write_is_nil_when_the_read_back_fails
    with_stub_bin("exit 1") do |stub|
      assert_nil CertEmission.missing_after_write(stub, "my-task", ["[unit] a"]),
                 "an unreadable read-back is UNVERIFIABLE — distinct from a confirmed loss"
    end
  end

  # ── [unit] Heartbeat — ORDERED SHUTDOWN ─────────────────────────────────────
  #
  # A beat is not a thread doing arithmetic; it is a thread that SPAWNS
  # `bin/gate`. `Thread#kill` unwinds the thread and leaves that child running, so
  # the lane's `running` row could land AFTER its pass/fail row — repainting a
  # settled lane as live, or (once the gate had closed) opening a phantom attempt
  # the board renders as a cert that never ends. Stopping must therefore WAIT for
  # the child, not kill the thread that is waiting on it.

  def test_unit_stop_waits_for_a_beat_already_in_flight
    events = []
    in_flight = Queue.new
    beat = CertEmission::Heartbeat.new(interval: 0.02) do
      events << :emit_started
      in_flight << :now
      sleep 0.3
      events << :emit_finished
    end

    in_flight.pop # the emit is spawned and mid-flight
    beat.stop
    events << :stop_returned

    assert_equal %i[emit_started emit_finished stop_returned], events,
                 "stop must not return while a `running` row is still in flight — that is the race"
  end

  def test_unit_no_beat_starts_after_stop
    beats = 0
    beat = CertEmission::Heartbeat.new(interval: 0.02) { beats += 1 }
    sleep 0.12
    beat.stop
    settled = beats
    sleep 0.15

    assert_operator settled, :>, 0, "the beat must actually have been beating for this to prove anything"
    assert_equal settled, beats, "no `running` row may be emitted after the terminal row"
  end

  # The signal path cannot use #stop: `Mutex#synchronize` RAISES in a trap
  # context, and a raise there costs the cert its reap. So #stop_now takes no
  # lock — and this test fails the moment somebody "tidies" it into one.
  def test_unit_stop_now_is_safe_inside_a_trap_handler
    beat = CertEmission::Heartbeat.new(interval: 5) { nil }
    raised = nil
    previous = Signal.trap("USR2") do
      begin
        beat.stop_now
      rescue StandardError, ThreadError => e
        raised = e
      end
    end

    Process.kill("USR2", Process.pid)
    sleep 0.1
    Signal.trap("USR2", previous || "DEFAULT")

    assert_nil raised, "the interrupt path must not take a lock (#{raised&.class})"
  end

  def test_unit_stop_heartbeat_tolerates_a_nil_beat
    assert_nil CertEmission.stop_heartbeat(nil), "a --print run has no beat to stop"
  end

  def test_unit_heartbeat_thread_beats_the_running_row
    with_logging_stub do |stub, log|
      beat = CertEmission.heartbeat_thread(stub, "my-task", "spine", "bin/rails test", interval: 0.02)
      sleep 0.1
      CertEmission.stop_heartbeat(beat)

      argv = logged_argv(log)
      assert_includes argv, "running"
      assert_equal ["sop", "task", "my-task", "g1_cert"], argv.first(4)
    end
  end

  def test_unit_heartbeat_thread_noops_without_a_slug
    assert_nil CertEmission.heartbeat_thread("/bin/true", "  ", "spine", "cmd"),
               "--print runs emit nothing durable, so there is nothing to beat"
  end

  # ── [unit] emit_interrupt_close ─────────────────────────────────────────────

  def test_unit_emit_interrupt_close_settles_the_lane_then_closes_the_gate
    with_logging_stub do |stub, log|
      CertEmission.emit_interrupt_close(stub, "my-task", "spine", "bin/rails test", "INT", 4321)
      argv = logged_argv(log)

      assert_includes argv, "fail", "an interrupted lane produced NO verdict — record it failed, not absent"
      assert_includes argv, "close"
      assert_includes argv, "--failed"
      assert_includes argv, "cause=interrupted"
      assert_includes argv, "signal=SIGINT"
      assert_operator argv.index("--duration-ms"), :<, argv.index("close"),
                      "the lane must settle BEFORE the gate closes, or the close carries no lane verdict"
    end
  end

  def test_unit_emit_interrupt_close_noops_without_a_slug
    with_logging_stub do |stub, log|
      CertEmission.emit_interrupt_close(stub, nil, "spine", "cmd", "TERM", 1)
      refute File.exist?(log), "--print runs have no gate to close"
    end
  end

  private

  # A stub executable that appends its argv (one per line) to a log file.
  def with_logging_stub
    Dir.mktmpdir do |dir|
      log = File.join(dir, "argv.log")
      stub = write_stub(dir, <<~SH)
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> #{log}; done
      SH
      yield stub, log
    end
  end

  def with_stub_bin(body)
    Dir.mktmpdir do |dir|
      yield write_stub(dir, "#!/bin/sh\n#{body}\n")
    end
  end

  def write_stub(dir, content)
    path = File.join(dir, "stub-bin")
    File.write(path, content)
    FileUtils.chmod("+x", path)
    path
  end

  def logged_argv(log)
    File.read(log).lines.map(&:chomp)
  end
end
