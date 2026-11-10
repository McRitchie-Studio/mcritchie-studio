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
#             global setup, or a red step the log names only by its ##[error] line.
#   product — a named test failed and the log shows the APP failing under it (a 500,
#             a template error, a backtrace through app/). The race is in the product.
#   test    — a named test failed and nothing points past the test itself.
# The class is a FIRST READ from the log; the builder who takes the card confirms it,
# and a product race is fixed in the product.
#
# SIGNAL ONLY (task ci-cause-detector-signal-only, after 2026-11-09, when one GitHub
# 504 on ruby/setup-ruby's download filed 15 cards, one per job per repo):
#   - An INFRA cause is outside every repo, so its card is keyed without the repo
#     (card_slug): one card per fault across all repos, each red job one occurrence.
#   - A job with no named fault is read by its FIRST ##[error] line, never the post-job
#     cleanup tail. A job with no ##[error] line yields no cause; CiCauseCardJob records
#     that red as an ErrorLog row, because a red is never dropped silently.
#   - A census job (executed-set) that names a shard whose report never arrived is a
#     FOLLOW-ON: its occurrence goes on the cause of that shard (attempt_causes).
#     So is a census red on a SHORT COUNT while a shard of its own lane failed: a
#     shard that died still uploads its empty report (if: always()), so every report
#     "arrives" and only the count says what was lost (turf run 42745469708).
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
    # A setup action (ruby/setup-ruby, actions/setup-node, …) that gave up on its
    # toolchain download. Read on the ##[error] line only: the action retries, and a
    # retried 504 that then succeeded prints the same words without failing the step.
    # Above http-429 and network, which a stalled download can also print.
    [/##\[error\].*(?:Unexpected HTTP response: 5\d\d|HTTP Error 5\d\d|Failed to download .*\b5\d\d\b)/i,
     "toolchain-download", "a setup action could not download its toolchain (the host answered 5xx)"],
    [/toomanyrequests|Data limit exceeded|pull rate limit/i, "image-pull-quota", "a container image pull was rate-limited"],
    [/can no longer be\s+found in that source|Could not find [\w.-]+-\d[\w.]* in (?:locally installed gems|rubygems repository)/i,
     "gem-index", "bundler could not resolve a locked gem (the gem index had not propagated)"],
    [/The runner has received a shutdown signal|lost communication with the server|runner .* did not respond/i,
     "runner-lost", "the hosted runner was lost mid-job"],
    [/HTTP 429|rate limits? exceeded/i, "http-429", "an external service answered HTTP 429"],
    [/ECONNRESET|ETIMEDOUT|Could not resolve host|Temporary failure in name resolution/i,
     "network", "a network call from the job failed"]
  ].freeze

  HARNESS = [
    # A native crash, not a slow boot (task ci-cause-card-dedupe-census, turf run
    # 42745469708): glibc's malloc abort killed the test server with exit 134, and
    # the old read filed it as "did not answer /up in time". Above web-server-boot,
    # which the same log also matches. Exit 134 is SIGABRT, 139 SIGSEGV, and 142 is
    # turf's native-abort-report shim ending an abort on its 30s SIGALRM; its banner
    # names the signal whatever the exit code, and Ruby's own crash report opens
    # "[BUG]". Never the shim's per-step
    # "ld.so: object ... native-abort-report.so cannot be preloaded" line: the host
    # docker CLI prints it on every green run.
    [/native-abort-report: SIG[A-Z]+|^(?:\[WebServer\] )?\[BUG\] |\b(?:Aborted|Segmentation fault) \(core dumped\)|\bmalloc\w*\(\): |free\(\): invalid|double free or corruption|config\.webServer[^\n]*Exit code: (?:134|139|142)\b|##\[error\]Process completed with exit code (?:134|139)\b/,
     "native-abort", "a native library crashed the process (SIGABRT or SIGSEGV), not a slow boot"],
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

  # Jobs that only re-count another job (the executed-set census). When the census
  # names a shard whose report never arrived, its red is that shard's red.
  ECHO_JOB = CiFailureDigest::ECHO_JOB
  ECHO_SUFFIX = /[\s_-]*(?:executed|declared)[_-]set\s*\z/i

  # A census lane word → the shard jobs it counts, when its own prefix does not name
  # them (turf's `e2e_executed_set` counts `playwright (N)`).
  LANES = { "e2e" => /playwright|e2e|browser/i, "rails" => /rails/i }.freeze

  # A census red because its lane ran FEWER specs or files than its contract.
  #   e2e:   "the lane EXECUTED 403 spec(s); config/e2e_lane.yml pins it at 614 (211 FEWER than the contract)"
  #   rails: "210 committed test file(s) executed NOTHING: …"
  SHORT_COUNT = /\bEXECUTED \d+ spec\(s\);[^\n]*\(\d+ FEWER than|committed test file\(s\) executed NOTHING/

  # A shard job's name: "… (n)" or "…(shard n/m)".
  SHARD_SUFFIX = /\((?:shard )?(\d+)(?:\/\d+)?\)\s*\z/

  # The classes whose cause lives outside any repo: one card across all repos.
  OUTSIDE = %w[infra].freeze

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
    error = lines.index { |l| l.start_with?("##[error]") }
    return [] unless error

    [cause("harness", nil, "job:#{job_name}", "the job failed with no test failure and no known setup fault in its log",
           context(lines, error))]
  end

  # PURE. One red attempt's failed jobs → what each one files, as
  # [{ job:, cause:, follows: }]. `jobs` is [{ name:, log: }]. A census job that names
  # a missing shard report FOLLOWS the failed shard job of that number: it gets that
  # job's causes, and `follows` names the shard job. A census that names no missing
  # report but is red on a short count follows every failed shard of its own lane. A job with no cause at all (no
  # ##[error] line) comes back once with `cause: nil`, for the caller to record.
  def attempt_causes(jobs)
    jobs = jobs.map { |j| j.to_h.transform_keys(&:to_sym) }
    echoes, real = jobs.partition { |j| j[:name].to_s.match?(ECHO_JOB) }
    own = real.to_h { |j| [j[:name].to_s, causes(job_name: j[:name], log: j[:log])] }
    out = own.flat_map { |name, list| entries(name, list, nil) }
    echoes.each do |echo|
      shards = missing_shards(echo[:log])
      targets = shards.filter_map { |n| shard_sibling(echo[:name], n, own.keys) }.uniq
      targets = lane_shards(echo[:name], own.keys) if shards.empty? && short_count?(echo[:log])
      followed = targets.flat_map { |t| own[t].map { |c| [t, c] } }
      out.concat(if followed.empty?
                   entries(echo[:name].to_s, causes(job_name: echo[:name], log: echo[:log]), nil)
                 else
                   followed.map { |t, c| { job: echo[:name].to_s, cause: c, follows: t } }
                 end)
    end
    out
  end

  def entries(name, list, follows)
    return [{ job: name, cause: nil, follows: follows }] if list.empty?

    list.map { |c| { job: name, cause: c, follows: follows } }
  end

  # PURE. A census log → the shard numbers whose report never arrived.
  #   e2e:   "expected one report from each of 3 shard(s) — [1, 2, 3] — but got [1, 3]"
  #   rails: "missing receipts for shard(s) 2, 4 of 4"
  def missing_shards(log)
    text = CiFailureDigest.clean(log).join("\n")
    if (m = text.match(/expected one report from each of \d+ shard\(s\) \S+ \[([\d, ]*)\] \S+ but got \[([\d, ]*)\]/))
      return ints(m[1]) - ints(m[2])
    end

    m = text.match(/missing receipts for shard\(s\) ([\d, ]+) of \d+/)
    m ? ints(m[1]) : []
  end

  def ints(list) = list.to_s.scan(/\d+/).map(&:to_i)

  # PURE. Did the census go red because its lane ran fewer specs or files than its contract?
  def short_count?(log) = CiFailureDigest.clean(log).any? { |l| l.match?(SHORT_COUNT) }

  # PURE. The failed shard jobs of a census's own lane: the jobs with a shard suffix
  # that its lane word names (LANES), else that share its prefix. A shard of another
  # lane is never followed.
  def lane_shards(echo_name, names)
    prefix = echo_name.to_s.sub(ECHO_SUFFIX, "")
    lane = LANES[prefix[/[a-z0-9]+\z/i].to_s.downcase]
    names.select { |name| name.match?(SHARD_SUFFIX) && (lane ? name.match?(lane) : name.start_with?(prefix)) }
  end

  # PURE. The failed shard job a census counts as shard `n`: a job named "… (n)" or
  # "…(shard n/m)". When two lanes have a shard n, the one that shares the census's
  # prefix wins, then the one its lane word names; past that, nil (never a guess).
  def shard_sibling(echo_name, n, names)
    hits = names.select { |name| name.match?(/\((?:shard )?#{n}(?:\/\d+)?\)\s*\z/) }
    return hits.first if hits.size <= 1

    prefix = echo_name.to_s.sub(ECHO_SUFFIX, "")
    by_prefix = hits.select { |name| name.start_with?(prefix) }
    return by_prefix.first if by_prefix.size == 1

    lane = LANES[prefix[/[a-z0-9]+\z/i].to_s.downcase]
    by_lane = lane ? hits.select { |name| name.match?(lane) } : []
    by_lane.size == 1 ? by_lane.first : nil
  end

  # The board slug for a cause: an outside (infra) cause is one card across repos,
  # `ci-cause-infra-<key>`; any other is the repo's own, `ci-cause-<repo>-<key>`.
  def card_slug(repo, cause)
    cause = cause.to_h.transform_keys(&:to_sym)
    outside?(cause) ? slug("infra", cause[:key]) : slug(repo, cause[:key])
  end

  def outside?(cause) = OUTSIDE.include?(cause.to_h.transform_keys(&:to_sym)[:klass].to_s)

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
    key = key.to_s
    short = if key.start_with?("job:")
      key.delete_prefix("job:").split(" / ").last.to_s
    else
      File.basename(key).sub(/\.spec\.[jt]s\z/, "")
    end
    "Find #{klass} cause #{short.squeeze(' ').strip}"
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
    i ? context(lines, i) : []
  end

  # Log chatter around a failing line that says nothing about the fault.
  NOISE = /\A(?:##\[(?:group|endgroup|command)\]|Waiting \d+ seconds|Took\s+[\d.]+ seconds|\s*at )|\A\s*\z/

  # The line at `i` and the three telling lines before it, oldest first.
  def context(lines, i)
    before = lines[0...i].reverse.reject { |l| l.match?(NOISE) }.first(3).reverse
    (before + [lines[i]]).map(&:strip).uniq
  end

  # The log lines of one failure's block: from its header to the next blank-line gap
  # of two, at most 40 lines. Where a backtrace through app/ would show.
  def failure_block(lines, failure)
    name = failure[:name].to_s.split(" › ").first.to_s
    start = lines.index { |l| l.include?(name) } || 0
    lines[start, 40].to_a
  end
end
