# frozen_string_literal: true

require "json"
require "open3"

# CiFailureDigest — WHAT FAILED, read from the failing jobs' own logs, printed at the
# seam that refuses a red CI (bin/submit 7/8). /tasks/submit-checks-before-push.
#
# WHY. In the 14 days to 2026-10-12, 230 of 407 builder-side DoR refusals were a red
# CI, and 130 tasks needed three or more submits. The refusal named the failing CHECKS
# ("ci / rails (3)"), never the failing TESTS, so a builder fixed the first failure it
# went looking for, pushed, and met the second one twelve minutes later. Printing every
# failing test with its message lets one fix pass cover them all.
#
# IT DECIDES NOTHING. dor-check owns the verdict; this only reads logs and prints. Every
# failure path — no gh, an unreadable log, a format it does not know — degrades to
# fewer lines, never to an exception or a changed exit code.
#
# The parser is PURE (extract / lines) and unit-tested against real log text in
# test/lib/ci_failure_digest_test.rb; collect is the thin gh shell around it.
module CiFailureDigest
  MAX_JOBS = 6
  MAX_FAILURES_PER_JOB = 6
  MAX_EXCERPT_LINES = 4

  # GitHub prefixes every log line with an ISO timestamp, and Playwright colours its
  # output; both are noise in a terminal excerpt.
  TIMESTAMP = /\A\d{4}-\d\d-\d\dT[\d:.]+Z ?/
  ANSI = /\e\[[0-9;]*m/

  # A failure in the job's SETUP, not in a test: the image pull or the network gave
  # out, and the remedy is a re-run, not a code change. Named so the builder does not
  # go hunting a bug that is not in the diff.
  INFRA = [
    [/toomanyrequests|Data limit exceeded|pull rate limit/i, "the container image pull was rate-limited"],
    [/HTTP 429|rate limits exceeded/i, "an external service answered HTTP 429 (rate limited)"],
    [/ECONNRESET|ETIMEDOUT|Could not resolve host/i, "a network call from the job failed"]
  ].freeze

  # Jobs that only re-count another job's result (the executed/declared-set census).
  # When a real job failed too, their red is the echo of it, so they are listed last
  # and never excerpted.
  ECHO_JOB = /_executed_set|_declared_set/

  module_function

  # "https://github.com/O/R/actions/runs/123/job/456" → ["O/R", "456"], else nil.
  def job_ref(link)
    m = link.to_s.match(%r{github\.com/([^/]+/[^/]+)/actions/runs/\d+/job(?:s)?/(\d+)})
    m && [m[1], m[2]]
  end

  def clean(log)
    # A job log can carry a byte that is not UTF-8; scrub it rather than raise on the regexps.
    log.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line.map { |l| l.sub(TIMESTAMP, "").gsub(ANSI, "").rstrip }
  end

  # PURE. A job log → { failures: [{ name:, location:, excerpt: [...] }], infra: "…"|nil }.
  # Minitest ("Failure:"/"Error:" blocks) and Playwright ("  1) [chromium] › …" blocks)
  # are read; a retried Playwright test is reported once.
  def extract(log)
    lines = clean(log)
    failures = minitest_failures(lines) + playwright_failures(lines)
    infra = INFRA.find { |pattern, _| lines.any? { |l| l.match?(pattern) } }&.last
    { failures: failures.uniq { |f| f[:name] }.first(MAX_FAILURES_PER_JOB), infra: infra }
  end

  # Failure:
  # SomeTest#test_name [test/x_test.rb:68]:     ← a Failure names its line here
  # message…
  #
  # Error:
  # SomeTest#test_name:                         ← an Error does not
  # Exception: message
  #     backtrace…
  #
  # bin/rails test test/x_test.rb:65            ← the rerun line, after the block
  def minitest_failures(lines)
    out = []
    lines.each_with_index do |line, i|
      next unless line == "Failure:" || line == "Error:"

      header = lines[i + 1].to_s
      m = header.match(/\A(\S+#\S+?)(?: \[([^\]]+)\])?:\z/) || header.match(/\A(\S+#.+?)(?: \[([^\]]+)\])?:\z/)
      next unless m

      body = lines[(i + 2)..].to_a.take_while { |l| !l.strip.empty? }
      rerun = lines[(i + 2)..].to_a.first(body.size + 4).find { |l| l.start_with?("bin/rails test ") }
      location = m[2] || rerun&.delete_prefix("bin/rails test ")
      out << { name: m[1], location: location, excerpt: body.first(MAX_EXCERPT_LINES).map(&:strip) }
    end
    out
  end

  #   1) [chromium] › e2e/x.spec.js:19:3 › Describe › title
  #
  #     Error: message
  #     Expected: …
  def playwright_failures(lines)
    out = []
    lines.each_with_index do |line, i|
      m = line.match(/\A\s*\d+\) \[[\w-]+\] › (\S+:\d+:\d+) › (.+?)\s*\z/)
      next unless m

      window = lines[(i + 1), 12].to_a
      start = window.index { |l| l.strip.start_with?("Error:") }
      # Playwright puts a blank line between the Error and its Expected/Received pair, and
      # follows them with the code frame ("> 124 |") and the stack ("at …"): keep the
      # message lines, stop at the frame.
      excerpt = if start
        window[start..].reject { |l| l.strip.empty? }
                       .take_while { |l| !l.strip.match?(/\A(>\s*)?\d+ \||\Aat |\Aattachment #/) }
      else
        []
      end
      out << { name: "#{m[1]} › #{m[2]}", location: m[1], excerpt: excerpt.first(MAX_EXCERPT_LINES).map(&:strip) }
    end
    out
  end

  # PURE. [{ job:, url:, failures:, infra:, unread: }] → printable lines.
  def lines(jobs)
    return [] if jobs.empty?

    real = jobs.reject { |j| j[:job].to_s.match?(ECHO_JOB) }
    echoes = jobs - real
    out = ["what failed (from the failing jobs' logs — fix all of these before the next push):"]
    real.each do |j|
      out << "  #{j[:job]}#{j[:url] ? "  #{j[:url]}" : ""}"
      out << "    ⚠ setup, not a test: #{j[:infra]} — re-run the job; nothing in the diff to fix" if j[:infra] && j[:failures].empty?
      out << "    (log unreadable: #{j[:unread]})" if j[:unread]
      out << "    (no test failure recognised in the log — open the job)" if !j[:unread] && !j[:infra] && j[:failures].empty?
      j[:failures].each do |f|
        out << "    ✗ #{f[:name]}#{f[:location] && !f[:name].include?(f[:location]) ? "  [#{f[:location]}]" : ""}"
        f[:excerpt].each { |e| out << "        #{e[0, 180]}" }
      end
    end
    unless echoes.empty?
      out << "  #{echoes.map { |j| j[:job] }.join(", ")} — census job(s): they re-count the jobs above" \
             "#{real.empty? ? "; open them" : " and clear when those do"}"
    end
    out
  end

  # The failing checks of a PR, each with its log read and parsed. `gh` is an injectable
  # runner (args → [output, ok]) so the IO path is testable without GitHub.
  def collect(pr_url, gh: method(:gh))
    raw, ok = gh.call(["pr", "checks", pr_url.to_s, "--json", "name,bucket,link"])
    return [] unless ok || raw.to_s.strip.start_with?("[") # `gh pr checks` exits 8 on a red PR

    # gh exits non-zero on a red PR, and a caller's runner (bin/submit's gh_capture)
    # then hands back stdout JOINED with stderr. gh prints the JSON on one stdout line,
    # so the first line is tried when the whole answer does not parse.
    checks = [raw.to_s, raw.to_s.lines.first.to_s].map { |text| parse_array(text) }.compact.first
    return [] unless checks.is_a?(Array) # no list to read is nothing to print, not an error

    failed = checks.select { |c| %w[fail cancel].include?(c["bucket"].to_s) }
    failed = failed.sort_by { |c| c["name"].to_s.match?(ECHO_JOB) ? 1 : 0 }.first(MAX_JOBS)
    failed.map do |c|
      ref = job_ref(c["link"])
      entry = { job: c["name"].to_s, url: c["link"], failures: [], infra: nil }
      next entry.merge(unread: "no job link") unless ref
      next entry if c["name"].to_s.match?(ECHO_JOB)

      log, read = gh.call(["api", "repos/#{ref[0]}/actions/jobs/#{ref[1]}/logs"])
      next entry.merge(unread: log.to_s.lines.first.to_s.strip[0, 100]) unless read

      begin
        entry.merge(extract(log))
      rescue StandardError => e # one unparseable log costs its own job, never the whole digest
        entry.merge(unread: "#{e.class}: #{e.message}"[0, 120])
      end
    end
  rescue StandardError => e
    [{ job: "(digest)", failures: [], infra: nil, unread: "#{e.class}: #{e.message}"[0, 120] }]
  end

  def parse_array(text)
    parsed = JSON.parse(text)
    parsed.is_a?(Array) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def gh(args)
    out, err, status = Open3.capture3(ENV.fetch("SHIP_GH_BIN", "gh"), *args)
    [status.success? ? out : (out.to_s.strip.empty? ? err : out), status.success?]
  rescue StandardError => e
    ["#{e.class}: #{e.message}", false]
  end
end
