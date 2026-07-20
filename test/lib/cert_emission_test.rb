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
    with_stub_bin("printf '%s' '{}'") do |stub|
      assert_equal [], CertEmission.fetch_checks(stub, "my-task"),
                   "[] = a task with none yet — distinct from nil (unreadable)"
    end
  end

  def test_unit_fetch_checks_is_nil_on_failure_or_bad_json
    with_stub_bin("exit 1") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"), "a red bin/task show = don't risk wiping"
    end
    with_stub_bin("printf '%s' '{nope'") do |stub|
      assert_nil CertEmission.fetch_checks(stub, "my-task"), "unparseable output = don't risk wiping"
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
