# frozen_string_literal: true

# WHAT A RELEASE CI GATE DOES WITH A RED VERDICT: stop and record it, or, for one
# named infrastructure cause, re-run it once and record THAT.
#
# THE RULING (Alex McRitchie, 2026-11-08). "Flaky" is not a category. A same-SHA
# red→green is a defect with a cause (infra, harness, test or product), never a
# retry. Until this ruling the gate re-ran a red first-attempt TEST LANE once by
# itself and shipped on the green (rel-20261108-730c77 did so on Cyvasse), which
# turned a nondeterministic test into a release that passed and a cause nobody
# looked for. So a red test lane now STOPS the gate, and the gate writes the
# failing run id, job names and spec locations on the release's gate record
# (`ci_red`), so the next agent starts from the evidence: find the cause, fix it
# forward through a task, re-run the cycle.
#
# THE ONE INFRA RE-RUN, kept on purpose. The ship itself publishes a gem and pushes
# the consumer re-lock commits; a consumer's `bundle install` can then run on a
# GitHub runner whose RubyGems CDN edge does not list the version yet ("Your bundle
# is locked to studio-engine (0.114.1) ... can no longer be found in that source",
# rantly run 40267136223; alex-build run 40938601557; voicebox scan_ruby run
# 42781359873 on rel-20261110-208612, a stock Rails CI with no runner wait). That red has a KNOWN cause
# outside the commit under test: the release's own publish racing the CDN. It is
# proven by bundler's own words in the failed job's log, not inferred from a
# job's name. Stopping on it would hand an operator a re-run with nothing to fix,
# because the commit is correct and only the CDN was late. So a red earns ONE
# `gh run rerun` (every job, so the executed-set guards re-read fresh receipts),
# recorded on the gate as `ci_infra_rerun` with the cause and run id, only when ALL
# of these hold for every failed workflow run on the SHA:
#
#   1. It failed on its FIRST attempt (`run_attempt == 1`).
#   2. It failed or timed out. A CANCELLED run is somebody's decision.
#   3. It was push- or pull_request-triggered (a schedule run tests production; a
#      workflow_dispatch run is a deploy, and a gate never re-dispatches one).
#   4. EVERY failing job in it shows bundler's gem-resolution error in its own
#      failed-step log. A job that failed any other way (an assertion, a lint
#      offence, a timeout in a test) is a finding, so the whole verdict stops.
#
# The durable fix for the race is the on-runner propagation wait,
# `.github/scripts/await-gem-propagation.sh` (turf-monster's own copy; every app on
# the hub's reusable-ci.yml runs the hub's). It reads /info as bundler does on several
# connections and fails as GEM_NOT_SERVED_ON_RUNNER, which this rule does not match,
# so a late CDN now stops the gate with a named cause. Every infra re-run still on
# the record is evidence that a consumer bundled without that wait.
#
# The caller (bin/release.rb#poll_ci_verdict) decides at most ONCE per repo and SHA
# per process and reads an infra re-run to its own conclusion. A red after it is
# real and stops the gate like any other.
#
# THE RUN MUST FINISH FIRST. A check-run goes red the moment one job fails, while
# the rest of its workflow run is still going; GitHub cannot re-run a run in
# progress, and the failing set is not final. So while any commit-triggered run on
# the SHA is unfinished (in_progress?) the caller holds and decides once it is done.
#
# PURE: facts in, a decision out. The gh reads and the re-run live in bin/release.
module CiRerun
  module_function

  # A job name that runs a suite. Matched case-insensitively against the job's
  # check-run name ("ci / rails (2)", "engine suite (bin/release-check)",
  # "browser lane (playwright)", "test", "system-test"). Used to label the record.
  TEST_LANE = /\b(test|tests|suite|system|e2e|playwright|browser|rails|spec|shard|executed[- ]set)\b/i

  # Words that make a job NOT a test lane even when a test word also appears
  # ("rails_plan", "Resolve consumer commits", "lint", "scan_ruby"). Checked first.
  NOT_TEST_LANE = /\b(lint|rubocop|brakeman|scan|scan_ruby|scan_js|audit|static|plan|rails_plan|refs|resolve|deploy)\b|_plan\b|scan_|lint_/i

  # Bundler's words when the lock names a version its source does not (yet) list.
  # The first is the 2026-10-26 rantly race verbatim; the others are the same
  # failure from `bundle install` on other bundler versions.
  RESOLUTION_ERROR = Regexp.union(
    /can no longer be found in that source/,
    /Could not find gem '[^']+' in (?:rubygems repository|any of the gem sources)/,
    /Could not find [\w.-]+-\d[\w.]* in (?:any of the sources|rubygems repository|locally installed gems)/
  )

  # A failing test's location as the suites print it: minitest (`bin/rails test
  # test/x_test.rb:43`), RSpec (`rspec ./spec/x_spec.rb:12`) and Playwright
  # (`e2e/survey_flow.spec.js:158:5`).
  SPEC_LOCATION = %r{(?<![\w/.-])((?:\./)?(?:[\w.-]+/)*[\w.-]+(?:_test\.rb|_spec\.rb|\.(?:spec|test)\.[cm]?[jt]sx?):\d+)}
  MAX_SPECS = 10

  INFRA_CAUSE = "RubyGems CDN race (bundler gem-resolution error in every failing job)"

  RERUN_CONCLUSIONS = %w[failure timed_out].freeze
  RERUN_EVENTS = %w[push pull_request].freeze

  # Is any commit-triggered workflow run on the SHA still unfinished? While one
  # is, a red check-run is an early read of a run that cannot yet be judged.
  def in_progress?(workflow_runs, sha)
    commit = sha.to_s.strip.downcase
    Array(workflow_runs).any? do |run|
      run.is_a?(Hash) && RERUN_EVENTS.include?(run["event"].to_s) && run["status"].to_s != "completed" &&
        (commit.empty? || run["head_sha"].to_s.strip.downcase == commit)
    end
  end

  def test_lane?(name)
    text = name.to_s
    return false if text.strip.empty?
    return false if text.match?(NOT_TEST_LANE)

    text.match?(TEST_LANE)
  end

  # `gh run view --log-failed` prefixes every line with "<job>\t<step>\t<timestamp> ",
  # and bundler wraps its message at 80 columns, so the phrase this matches arrives
  # split across lines: "...can no longer be" / "<job>\t<step>\t<ts> found in that
  # source". rel-20261029-00560a (alex-build run 40938601557, voicebox 40938649188):
  # the raw log never matched. So the log is unwrapped first.
  LOG_PREFIX = /^(?:[^\t\n]*\t){2}(?=\d{4}-\d\d-\d\dT)|^\d{4}-\d\d-\d\dT[\d:.]+Z ?/
  JOB_COLUMN = /\A([^\t\n]*)\t[^\t\n]*\t\d{4}-\d\d-\d\dT/

  def resolution_error?(log)
    unwrap_log(log).match?(RESOLUTION_ERROR)
  end

  # A suite's own report: a minitest/RSpec/Playwright tally or a failure header.
  TEST_RAN = /\d+ (?:runs|examples|tests?), \d+ (?:assertions|failures)|\b\d+ (?:failed|passed)\b|^\s*(?:Failure|Error):\s*$/

  # The race and nothing else: bundler's error, and no test ran or failed in the job.
  # A test that prints the phrase (a gem-resolution test, a fixture in a diff) names
  # its spec location, so it stays a finding.
  def race_only?(log)
    resolution_error?(log) && specs_in(log).empty? && !log.to_s.each_line.any? { |l| l.sub(LOG_PREFIX, "").sub(LOG_PREFIX, "").match?(TEST_RAN) }
  end

  # PURE. The log as one line of prose: job/step/timestamp prefixes dropped, every
  # run of whitespace (the wraps included) collapsed to one space.
  def unwrap_log(log)
    log.to_s.each_line.map { |line| line.sub(LOG_PREFIX, "").sub(LOG_PREFIX, "") }.join(" ").gsub(/\s+/, " ")
  end

  # PURE. { job name => its lines } from a `--log-failed` log's first column. Empty
  # when the log carries no job column (the job-log API shape).
  def log_by_job(log)
    log.to_s.each_line.each_with_object({}) do |line, groups|
      job = line[JOB_COLUMN, 1]
      (groups[job] ||= +"") << line if job
    end
  end

  # PURE. The failing jobs, each with the slice of the log that is its own. A job
  # matches its log column by equal name or by the last " / " segment (a reusable
  # workflow's "ci / rails" against "rails"). Only when the log names NONE of the
  # failing jobs does each job stand on the whole log; a job the log does not name
  # while it names others gets an empty slice, so it can never borrow another
  # job's resolution error.
  def job_logs(jobs, log)
    groups = log_by_job(log)
    found = jobs.to_h { |job| [job, groups.find { |key, _| same_job?(key, job) }&.last] }
    return jobs.to_h { |job| [job, log.to_s] } if found.values.all?(&:nil?)

    found.transform_values(&:to_s)
  end

  def same_job?(key, job)
    a = key.to_s.strip
    b = job.to_s.strip
    a == b || a.split(" / ").last == b.split(" / ").last
  end

  # PURE. The failing test locations a log names, deduped, at most MAX_SPECS.
  def specs_in(log)
    unwrap_log(log).scan(SPEC_LOCATION).flatten.map { |s| s.delete_prefix("./") }.uniq.first(MAX_SPECS)
  end

  # The failed workflow runs on a SHA, from the Actions API's `workflow_runs`.
  def failed_runs(workflow_runs, sha)
    commit = sha.to_s.strip.downcase
    Array(workflow_runs).select do |run|
      run.is_a?(Hash) && run["status"].to_s == "completed" &&
        %w[failure timed_out cancelled startup_failure action_required].include?(run["conclusion"].to_s) &&
        (commit.empty? || run["head_sha"].to_s.strip.downcase == commit)
    end
  end

  # THE DECISION. `runs` are the SHA's failed workflow runs (failed_runs);
  # `jobs_by_run` maps a run id to its failing job names; `log_for` answers a run's
  # failed-step log, read once per run (the record needs its spec locations either
  # way). Returns
  #   { action: :rerun, cause: "infra", run_ids: [...], reason: "...", failures: [...] }  or
  #   { action: :stop, reason: "...", failures: [...] }
  # where each failure is { "run_id", "name", "conclusion", "attempt", "jobs", "test_lanes", "specs" }.
  def plan(runs:, jobs_by_run:, log_for: ->(_id) { "" })
    runs = Array(runs)
    if runs.empty?
      return { action: :stop, failures: [],
               reason: "no completed failed workflow run found on the SHA (a red check-run with no run to read)" }
    end

    failures = []
    blockers = []
    infra = []
    runs.each do |run|
      id = run["id"]
      label = "#{run['name'] || 'workflow'} (run #{id})"
      jobs = Array(jobs_by_run[id]).map(&:to_s)
      log = log_for.call(id).to_s
      logs = job_logs(jobs, log)
      failures << { "run_id" => id, "name" => run["name"].to_s, "conclusion" => run["conclusion"].to_s,
                    "attempt" => run["run_attempt"].to_i, "jobs" => jobs,
                    "test_lanes" => jobs.select { |job| test_lane?(job) }, "specs" => specs_in(log) }

      if (why = infra_ineligible(run, jobs))
        blockers << "#{label} #{why}"
        next
      end

      plain = jobs.reject { |job| race_only?(logs[job]) }
      if plain.any?
        kind = plain.all? { |job| test_lane?(job) } ? "test lane" : "job"
        blockers << "#{label}: #{kind}#{plain.size == 1 ? '' : 's'} #{plain.join(', ')} failed with no " \
                    "gem-resolution error — a red with a cause to find, never a retry"
        next
      end
      infra << "#{label}: #{jobs.join(', ')} hit bundler's gem-resolution error (the RubyGems CDN race)"
    end

    return { action: :stop, reason: blockers.join("; "), failures: failures } if blockers.any?

    { action: :rerun, cause: "infra", run_ids: runs.map { |r| r["id"] }, reason: infra.join("; "), failures: failures }
  end

  # Why a run cannot be the infra re-run, or nil when rules 1-3 hold and it names jobs.
  def infra_ineligible(run, jobs)
    event = run["event"].to_s
    return "was schedule-triggered — it does not test this commit" if event == "schedule"
    return "was #{event.inspect}-triggered — a gate never re-runs a dispatched deploy" unless RERUN_EVENTS.include?(event)
    return "concluded #{run['conclusion']}" unless RERUN_CONCLUSIONS.include?(run["conclusion"].to_s)

    attempt = run["run_attempt"].to_i
    return "is on attempt #{attempt} — it was already re-run once; this red is real" if attempt != 1
    return "names no failing job to judge" if jobs.empty?

    nil
  end

  # PURE. The one-line record of a stopped red for the gate's `ci_red` SOP: each
  # run's id, failing jobs and spec locations, then what to do.
  def red_record(repo, short_sha, failures, reason)
    runs = Array(failures).map do |f|
      specs = Array(f["specs"])
      "run #{f['run_id']} (#{f['name'].to_s.empty? ? 'workflow' : f['name']}, attempt #{f['attempt']}): " \
        "jobs #{Array(f['jobs']).join(', ').then { |j| j.empty? ? '(none read)' : j }}; " \
        "specs #{specs.empty? ? '(none named in the log)' : specs.join(', ')}"
    end
    "✗ CI RED #{repo}@#{short_sha} — #{runs.empty? ? 'no failed run read' : runs.join(' | ')}. #{reason}. " \
      "Find the cause (infra, harness, test or product), fix it forward through a task, re-run the cycle; " \
      "never a hand re-run."
  end

  # Has every re-run been picked up AND concluded? A re-run only counts as the
  # second verdict once GitHub shows a later attempt that has completed; until
  # then the SHA's check-runs can still be the FIRST attempt's red.
  def settled?(runs_now, run_ids)
    by_id = Array(runs_now).select { |r| r.is_a?(Hash) }.to_h { |r| [r["id"], r] }
    Array(run_ids).all? do |id|
      run = by_id[id]
      run && run["run_attempt"].to_i >= 2 && run["status"].to_s == "completed"
    end
  end
end
