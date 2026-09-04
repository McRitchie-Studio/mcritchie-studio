# frozen_string_literal: true

require "test_helper"
require_relative "../../bin/lib/importmap_audit"

# The distinction this module draws IS the fix, so the tests are built around
# the two ways of getting it wrong: calling a real advisory a timeout (which
# would silently ship a vulnerability), and calling a timeout an advisory
# (which is the bug that red-sealed a release five times).
class ImportmapAuditTest < ActiveSupport::TestCase
  # The literal output the runner produced on 2026-09-03, trimmed. Written from
  # the real log rather than invented, so the matcher is shaped by what
  # importmap-rails actually prints and not by what I imagined it prints.
  TIMEOUT_OUTPUT = <<~OUT
    vendor/bundle/ruby/3.3.0/gems/importmap-rails-2.2.3/lib/importmap/npm.rb:142:in `rescue in post_json': Unexpected transport error (Net::ReadTimeout: Net::ReadTimeout with #<TCPSocket:(closed)>) (Importmap::Npm::HTTPError)
    \tfrom vendor/bundle/ruby/3.3.0/gems/importmap-rails-2.2.3/lib/importmap/npm.rb:139:in `post_json'
    \tfrom vendor/bundle/ruby/3.3.0/gems/net-protocol-0.2.2/lib/net/protocol.rb:229:in `rbuf_fill'
  OUT

  # CUT FROM THE PRODUCER, NOT IMAGINED. Rendered exactly as
  # importmap-rails-2.2.3 puts_table emits it (commands.rb:155-167): every row
  # is `"| " + row.join(" | ") + " |"`, columns padded to the widest cell, a
  # divider under the header, and the summary line carrying TWO leading spaces
  # plus a severity tally.
  #
  # The previous fixture here was space-delimited because that is what a table
  # looks like if you picture one instead of reading the gem. It passed, and it
  # let a dead regex sit in the classifier looking live.
  # The summary line specifically — not "any line mentioning a vulnerability",
  # which would also match the header's own column name.
  SUMMARY_PATTERN = /vulnerabilit(?:y|ies)\s+found/i

  VULNERABLE_OUTPUT = <<~OUT
    | Package | Severity | Vulnerable versions | Vulnerability       |
    |---------|----------|---------------------|---------------------|
    | lodash  | high     | < 4.17.21           | Prototype pollution |
      1 vulnerability found: 1 high
  OUT

  test "a registry timeout is unreachable, not a finding" do
    assert_equal :unreachable,
                 ImportmapAudit.verdict(output: TIMEOUT_OUTPUT, status: 1)
  end

  test "a reported vulnerability fails, and is never excused as a timeout" do
    assert_equal :vulnerable,
                 ImportmapAudit.verdict(output: VULNERABLE_OUTPUT, status: 1)
  end

  test "a clean run passes" do
    assert_equal :pass, ImportmapAudit.verdict(output: "No vulnerabilities found\n", status: 0)
  end

  # The dangerous ambiguity: output that carries BOTH a real finding and some
  # incidental socket noise. Treating that as unreachable would ship the
  # vulnerability, so the finding must win.
  test "a finding wins even when transport noise is present" do
    mixed = VULNERABLE_OUTPUT + "\nWarning: Net::ReadTimeout while fetching changelog\n"

    refute ImportmapAudit.transport_failure?(mixed),
           "a run that REPORTED vulnerabilities must never be excused as a network failure"
    assert_equal :vulnerable, ImportmapAudit.verdict(output: mixed, status: 1)
  end

  # A zero exit with a vulnerability table would be importmap changing its
  # contract under us. Fail closed rather than trusting the status alone.
  test "a vulnerability table beats a zero exit status" do
    assert_equal :vulnerable, ImportmapAudit.verdict(output: VULNERABLE_OUTPUT, status: 0)
  end

  # THE ARM THAT WAS DEAD. Asserted on its own, so it cannot go back to being
  # decoration behind the summary line: strip the summary and the table alone
  # must still read as a finding.
  test "the table header alone is a finding, without the summary line" do
    # Strip the SUMMARY line only. Rejecting every line matching /vulnerabilit/i
    # would also delete the header row, whose fourth column is literally
    # "Vulnerability" — leaving this test asserting on a divider.
    table_only = VULNERABLE_OUTPUT.lines.reject { |l| l.match?(SUMMARY_PATTERN) }.join

    refute_match(SUMMARY_PATTERN, table_only, "the summary must really be gone for this to mean anything")
    assert_match(/Package/, table_only, "the header must survive, or this asserts nothing")
    assert ImportmapAudit.vulnerabilities_reported?(table_only),
           "the pipe-delimited table the gem actually prints must be recognised on its own"
    assert_equal :vulnerable, ImportmapAudit.verdict(output: table_only, status: 1)
  end

  # And the summary alone, for the same reason in the other direction.
  test "the summary line alone is a finding, without the table" do
    summary_only = "  1 vulnerability found: 1 high\n"

    assert ImportmapAudit.vulnerabilities_reported?(summary_only)
    assert_equal :vulnerable, ImportmapAudit.verdict(output: summary_only, status: 1)
  end

  test "every transport signature is recognised" do
    ImportmapAudit::TRANSPORT_SIGNATURES.each do |sig|
      sample = "some prefix #{sig.source.gsub('\\', '')} some suffix"
      assert ImportmapAudit.transport_failure?(sample),
             "#{sig.inspect} is listed but does not match its own text"
    end
  end

  # A non-zero exit we cannot explain is NOT excused. Only a recognised
  # transport signature earns the pass; anything else stays a failure.
  test "an unexplained failure is not excused" do
    assert_equal :vulnerable,
                 ImportmapAudit.verdict(output: "something went wrong, no idea what", status: 1)
  end
end
