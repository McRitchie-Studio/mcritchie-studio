# frozen_string_literal: true

require "digest"
require_relative "ci_failure_digest"

# CiCauseDetector — A SAME-SHA RED THEN GREEN IS A DEFECT WITH A CAUSE.
#
# THE RULING. Alex McRitchie, 2026-11-06: "Flaky is a terrible way to describe a
# system." A run that goes red and then green at the same SHA is not noise to retry
# and log; it is a defect, and somebody owes its cause. This module turns each such
# flip into CAUSES: one per failing test or setup fault, each classed and keyed, so
# the hub files one board card per cause (Ci::CauseCard) and folds every later
# occurrence of the same cause into that card.
#
# THE FOUR CLASSES, read in this order (named failures first, see causes()).
#   infra   — the job's machinery gave out before or around the test: an apt mirror,
#             an image pull quota, the network, a lost runner, the gem index.
#   harness — the test rig, not a test: the test server or the browser lane's boot,
#             global setup, an executed-set census that echoes another job.
#   product — a named test failed and the log shows the APP failing under it (a 500,
#             a template error, a backtrace through app/). The race is in the product.
#   test    — a named test failed and nothing points past the test itself.
# The class is a FIRST READ from the log; the builder who takes the card confirms it,
# and a product race is fixed in the product.
#
# IT IS PURE. flips() reads run rows, causes() reads one job's log; the IO (GitHub
# reads, the board write) lives in app/jobs/ci_cause_card_job.rb. The log parser is
# CiFailureDigest's, the one bin/submit already prints red CI with.
# Unit tests: test/lib/ci_cause_detector_test.rb. Task: deterministic-ci.
module CiCauseDetector
  CLASSES = %w[infra harness test product].freeze
  RED = %w[failure timed_out].freeze

  # [pattern, key, reason]: the first match names the fault. Order matters: a stalled
  # apt mirror also prints network errors, and the specific name should win.
  INFRA = [
    [/apt-get failed every attempt|E: Failed to fetch|Unable to fetch some archives|Could not get lock \/var\/lib\/(?:dpkg|apt)/i,
     "apt-mirror", "an apt mirror stalled or refused a package fetch"],
    [/toomanyrequests|Data limit exceeded|pull rate limit/i, "image-pull-quota", "a container image pull was rate-limited"],
    [/can no longer be found in that source|Could not find [\w.-]+-\d[\w.]* in (?:locally installed gems|rubygems repository)/i,
     "gem-index", "bundler could not resolve a locked gem (the gem index had not propagated)"],
    [/The runner has received a shutdown signal|lost communication with the server|runner .* did not respond/i,
     "runner-lost", "the hosted runner was lost mid-job"],
    [/HTTP 429|rate limits? exceeded/i, "http-429", "an external service answered HTTP 429"],
    [/ECONNRESET|ETIMEDOUT|Could not resolve host|Temporary failure in name resolution/i,
     "network", "a network call from the job failed"]
  ].freeze

  HARNESS = [
    [/Timed out waiting \d+ms from config\.webServer|Process from config\.webServer (?:was not able to start|exited early)/i,
     "web-server-boot", "the test server did not answer /up in time"],
    [/Error: .*globalSetup|in global setup/i, "global-setup", "the browser lane's global setup failed"],
    [/net::ERR_CONNECTION_REFUSED|connect ECONNREFUSED 127\.0\.0\.1/i, "server-refused", "the browser could not reach the test server"]
  ].freeze

  # The app failing under a test, as a log shows it.
  PRODUCT = [
    /ActionView::Template::Error/,
    /Internal Server Error|status(?: code)?:? 500\b|\b500 \(Internal/i,
    /^\s*(?:\/\S+\/)?app\/(?:models|controllers|services|jobs|views|helpers|components|javascript)\/\S+:\d+/
  ].freeze

  # Jobs that only re-count another job (the executed-set census). Their red is the
  # echo of a shard's red, never a cause of its own.
  ECHO_JOB = CiFailureDigest::ECHO_JOB

  module_function

  # PURE. Run rows → the reds a later green proved, as
  # [{ red: {run_id:, attempt:}, green: {run_id:, attempt:}, sha:, workflow: }].
  # A row is { run_id:, attempt:, conclusion:, sha:, workflow: } (strings or symbols).
  # Two shapes are a flip: an attempt that failed and a later attempt of the SAME run
  # that passed (a re-run), and two RUNS of one workflow at one SHA, one red, one green.
  def flips(rows)
    rows = rows.map { |r| normalize(r) }
    out = []
    rows.group_by { |r| [r[:workflow], r[:sha]] }.each do |(workflow, sha), group|
      green = group.select { |r| r[:conclusion] == "success" }.max_by { |r| [r[:attempt], r[:run_id]] }
      next unless green

      group.select { |r| RED.include?(r[:conclusion]) }.each do |red|
        out << { red: red.slice(:run_id, :attempt), green: green.slice(:run_id, :attempt), sha: sha, workflow: workflow }
      end
    end
    out.uniq { |f| f[:red] }
  end

  # PURE. One failed job's log → its causes,
  # [{ klass:, key:, reason:, evidence: [..] }]. A NAMED test failure is the most
  # concrete evidence a log holds, so it is read first: a passing test may print
  # "ECONNREFUSED" on purpose (the nflverse outage tests did), and that line must not
  # turn a real test failure into "infra". Only a job with no named failure is read
  # for a setup fault (infra, then harness): when the apt step stalls or the server
  # never boots, no test runs and no test is named.
  def causes(job_name:, log:)
    return [] if job_name.to_s.match?(ECHO_JOB)

    lines = CiFailureDigest.clean(log)
    failures = CiFailureDigest.extract(log)[:failures]
    unless failures.empty?
      return failures.map do |f|
        block = failure_block(lines, f)
        klass = PRODUCT.any? { |re| block.any? { |l| l.match?(re) } } ? "product" : "test"
        reason = klass == "product" ? "#{f[:name]} failed and the app raised under it" : "#{f[:name]} failed"
        cause(klass, nil, test_key(f), reason, f[:excerpt])
      end.uniq { |c| c[:key] }
    end

    text = lines.join("\n")
    [[INFRA, "infra"], [HARNESS, "harness"]].each do |table, klass|
      hit = first_match(table, text)
      return [cause(klass, *hit, evidence_for(lines, hit.first))] if hit
    end
    [cause("harness", nil, "job:#{job_name}", "the job failed with no test failure and no known setup fault in its log", lines.last(4))]
  end

  # The stable name of a failing test's cause: its spec FILE (a Playwright spec, which
  # can fail at many lines for one race) or its Minitest CLASS.
  def test_key(failure)
    loc = failure[:location].to_s
    return loc.sub(/:\d+(?::\d+)?\z/, "") if loc.match?(/\.spec\.[jt]s/)

    failure[:name].to_s.split("#").first
  end

  # A board slug for the cause, stable across occurrences: `ci-cause-<repo>-<key>`,
  # shortened with a digest when the key is long.
  def slug(repo, key)
    base = "ci-cause-#{repo.to_s.split('/').last}-#{key}".downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    return base if base.length <= 60

    "#{base[0, 51].chomp('-')}-#{Digest::SHA256.hexdigest(base)[0, 8]}"
  end

  # Three to five words, as the board wants.
  def title(klass, key)
    short = File.basename(key.to_s).sub(/\.spec\.[jt]s\z/, "").sub(/\Ajob:/, "")
    "Find #{klass} cause #{short}"
  end

  def normalize(row)
    h = row.to_h.transform_keys(&:to_sym)
    { run_id: h[:run_id].to_i, attempt: (h[:attempt] || 1).to_i, conclusion: h[:conclusion].to_s,
      sha: h[:sha].to_s, workflow: h[:workflow].to_s }
  end

  def first_match(table, text)
    row = table.find { |re, _, _| text.match?(re) }
    row && [row[0], row[1], row[2]]
  end

  def cause(klass, _pattern, key, reason, evidence)
    { klass: klass, key: key, reason: reason, evidence: Array(evidence).map(&:to_s).first(4) }
  end

  def evidence_for(lines, pattern)
    i = lines.index { |l| l.match?(pattern) }
    i ? lines[[i - 1, 0].max, 3].map(&:strip).reject(&:empty?) : []
  end

  # The log lines of one failure's block: from its header to the next blank-line gap
  # of two, at most 40 lines. Where a backtrace through app/ would show.
  def failure_block(lines, failure)
    name = failure[:name].to_s.split(" › ").first.to_s
    start = lines.index { |l| l.include?(name) } || 0
    lines[start, 40].to_a
  end
end
