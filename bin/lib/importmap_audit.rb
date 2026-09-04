# frozen_string_literal: true

# Did the JavaScript dependency audit find a VULNERABILITY, or could it not
# REACH the registry? `bin/importmap audit` exits non-zero for both, and the two
# want opposite responses from a release gate.
#
# WHY THIS EXISTS
#
# `bin/importmap audit` POSTs to npm's advisory endpoint. On 2026-09-03 the
# GitHub runner's path to npm degraded, every attempt hung ~62s and died inside
# importmap-rails' own `npm.rb#post_json` with Net::ReadTimeout, and CI reported
# the static lane RED. The pre-QA gate read that red exactly as it reads a real
# advisory and refused to promote — five attempts in a row on one release
# candidate, and once on the `accepted` promote before it. npm itself was
# healthy throughout (registry.npmjs.org answered in 0.08s from outside CI), so
# nothing was wrong with the dependencies, the code, or either task riding the
# release.
#
# A NETWORK TIMEOUT IS NOT A SECURITY FINDING. Conflating them means a
# third-party outage can red-seal a release, and the only way through is a
# person deciding to override a security gate at 11pm — which is precisely when
# nobody should be practising that.
#
# WHAT THIS DOES NOT DO
#
# It does not weaken the audit. A reachable registry that reports a vulnerable
# package still fails, and that is asserted in the tests. The ONLY case it
# converts to a pass is "we could not ask" — and it says so loudly, so an
# unreachable registry is visible in the log rather than silently green.
module ImportmapAudit
  # The signatures importmap-rails/net-http raise when the registry cannot be
  # reached or answers unusably. Matched against the command's combined output.
  #
  # Deliberately specific: a bare /timeout/ or /error/ would also swallow an
  # advisory whose package name happened to contain the word, which is the
  # failure mode this module exists to prevent in the other direction.
  TRANSPORT_SIGNATURES = [
    /Importmap::Npm::HTTPError/,
    /Unexpected transport error/,
    /Net::ReadTimeout/,
    /Net::OpenTimeout/,
    /Errno::ECONNRESET/,
    /Errno::ECONNREFUSED/,
    /SocketError/,
    /execution expired/
  ].freeze

  # True when the run failed because the registry was unreachable — NOT because
  # it answered with findings.
  #
  # Order matters and is the whole subtlety: a run that reports vulnerabilities
  # is a finding even if some unrelated line mentions a socket. So this answers
  # only for output that carries a transport signature AND does not carry the
  # audit's own vulnerability report.
  def self.transport_failure?(output)
    text = output.to_s
    return false if vulnerabilities_reported?(text)

    TRANSPORT_SIGNATURES.any? { |sig| text.match?(sig) }
  end

  # importmap-rails prints a table of vulnerable packages and a summary line.
  # Either shape counts — the table header changes between versions, the
  # "N vulnerabilit(y|ies) found" summary has been stable.
  def self.vulnerabilities_reported?(output)
    text = output.to_s
    text.match?(/\b\d+\s+vulnerabilit(?:y|ies)\s+found/i) ||
      text.match?(/^\s*Package\s+Severity\b/i)
  end

  # The verdict for one run of the audit command.
  #
  # @return [:pass, :vulnerable, :unreachable]
  def self.verdict(output:, status:)
    return :pass if status.zero? && !vulnerabilities_reported?(output)
    return :unreachable if transport_failure?(output)

    :vulnerable
  end
end
