# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# The wrapper end to end, driven against fake audit commands.
#
# The unit test proves the classifier draws the right line; this proves the
# script ACTS on it — that a timeout really exits 0 and a finding really exits
# 1. Those exit codes are what CI reads, so asserting the classifier alone
# would leave the part the release gate actually sees untested.
class ImportmapAuditCiTest < ActiveSupport::TestCase
  WRAPPER = Rails.root.join("bin/importmap-audit-ci").to_s

  # A stand-in for `bin/importmap audit`: prints what we tell it, exits how we
  # tell it. The wrapper takes its command from IMPORTMAP_AUDIT_COMMAND, which
  # exists for exactly this.
  def fake_audit(dir, output:, exit_code:, name: "fake-audit")
    path = File.join(dir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      cat <<'AUDIT_OUTPUT'
      #{output}
      AUDIT_OUTPUT
      exit #{exit_code}
    SH
    File.chmod(0o755, path)
    path
  end

  def run_wrapper(command, attempts: 2, backoff: 0)
    Open3.capture2e(
      { "IMPORTMAP_AUDIT_COMMAND" => command,
        "IMPORTMAP_AUDIT_ATTEMPTS" => attempts.to_s,
        "IMPORTMAP_AUDIT_BACKOFF" => backoff.to_s },
      WRAPPER
    )
  end

  test "a clean audit exits 0" do
    Dir.mktmpdir do |dir|
      cmd = fake_audit(dir, output: "No vulnerabilities found", exit_code: 0)
      out, status = run_wrapper(cmd)

      assert_equal 0, status.exitstatus, out
      assert_match(/clean/, out)
    end
  end

  # The whole point: an unreachable registry must not fail the lane — and must
  # not pretend it audited anything either.
  test "a registry timeout exits 0 and says loudly that no audit happened" do
    Dir.mktmpdir do |dir|
      cmd = fake_audit(dir,
                       output: "Unexpected transport error (Net::ReadTimeout) (Importmap::Npm::HTTPError)",
                       exit_code: 1)
      out, status = run_wrapper(cmd, attempts: 2)

      assert_equal 0, status.exitstatus, out
      assert_match(/DID NOT RUN/, out)
      assert_match(/NOT a clean audit/, out)
      assert_match(/unreachable on attempt 1\/2/, out)
      assert_match(/unreachable on attempt 2\/2/, out)
    end
  end

  # The other half, and the one that would matter most if it broke: the fix
  # must not have turned the audit off.
  test "a real vulnerability still fails the lane" do
    Dir.mktmpdir do |dir|
      cmd = fake_audit(dir, output: "Package Severity\nlodash high\n1 vulnerability found", exit_code: 1)
      out, status = run_wrapper(cmd)

      assert_equal 1, status.exitstatus, out
      assert_match(/VULNERABILITIES REPORTED/, out)
    end
  end

  test "an unexplained non-zero exit still fails the lane" do
    Dir.mktmpdir do |dir|
      cmd = fake_audit(dir, output: "bin/importmap: command borked", exit_code: 127)
      _out, status = run_wrapper(cmd)

      assert_equal 1, status.exitstatus
    end
  end

  # A transport blip that clears on the retry should pass as a genuine clean
  # audit — not as the "we could not ask" banner.
  test "a timeout that recovers on retry reports a real clean audit" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "attempted")
      path = File.join(dir, "flaky-audit")
      File.write(path, <<~SH)
        #!/bin/sh
        if [ -f "#{marker}" ]; then
          echo "No vulnerabilities found"
          exit 0
        fi
        touch "#{marker}"
        echo "Unexpected transport error (Net::ReadTimeout) (Importmap::Npm::HTTPError)"
        exit 1
      SH
      File.chmod(0o755, path)

      out, status = run_wrapper(path, attempts: 3)

      assert_equal 0, status.exitstatus, out
      assert_match(/clean \(attempt 2\/3\)/, out)
      refute_match(/DID NOT RUN/, out)
    end
  end
end
