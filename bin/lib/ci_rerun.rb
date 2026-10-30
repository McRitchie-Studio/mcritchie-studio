# frozen_string_literal: true

# THE ONE AUTOMATIC RE-RUN a release CI gate may spend on a red verdict.
#
# WHY IT EXISTS. Two kinds of red stopped the 2026-10-25/26 sweeps that no code
# change could fix:
#
#   * A FLAKY TEST LANE. The engine's `e2e/survey_flow.spec.js:158` (run
#     40258947707: the same SHA was green in a parallel run) and rantly's
#     `test/integration/production_ssl_test.rb:43` (run 40237591268: green on
#     re-run and locally). Each stopped `prepare` and needed a hand re-run.
#   * THE GEM-INDEX RACE. The ship published studio-engine 0.114.1 and pushed the
#     consumer re-lock commits; rantly's `scan_js` and `lint` ran `bundle install`
#     before the runner's RubyGems CDN edge served the version ("Your bundle is
#     locked to studio-engine (0.114.1) ... can no longer be found in that source",
#     run 40267136223). The conductor's own wait had passed: it proves what the
#     CONDUCTOR's edge serves, never the edge a GitHub runner hits minutes later,
#     and rantly's CI carries no on-runner propagation wait (turf-monster's
#     `.github/scripts/await-gem-propagation.sh` is that wait). A re-run was green.
#
# THE RULE, narrow on purpose. A red verdict earns ONE `gh run rerun` (every job
# of the run, so the executed-set guards re-read fresh receipts) only when ALL of
# these hold, and every failed workflow run on the SHA meets them:
#
#   1. The run failed on its FIRST attempt (`run_attempt == 1`): this SHA has never
#      failed that lane before and been re-run. A lane that already failed once
#      and was re-run gets no second chance from the conductor.
#   2. It failed, or timed out. A CANCELLED run is somebody's decision, never a flake.
#   3. It was not schedule-triggered (a nightly tests production, not the commit;
#      CiStatus already leaves it out of the fold).
#   4. Every failing job in it is a TEST LANE (a suite, a shard, the browser lane,
#      their executed-set aggregate) OR its failed-step log carries bundler's
#      gem-resolution error. A failing lint, scan, audit or plan job with no
#      resolution error is a real finding: no re-run.
#
# The caller (bin/release.rb#poll_ci_verdict) spends it at most ONCE per repo and
# SHA per process, says so loudly, and reads the re-run to a conclusion. A second
# red is real and fails the gate exactly as the first would have.
#
# THE RUN MUST FINISH FIRST. A check-run goes red the moment one job fails, while
# the rest of its workflow run is still going, and GitHub cannot re-run a run that
# is in progress. On 2026-10-27 the ship's gate read that early red, found no
# COMPLETED failed run, printed "no failed workflow run found on the SHA to re-run"
# and spent its one chance on nothing. So while any commit-triggered run on the SHA
# is unfinished (in_progress?) the caller holds, and decides only once it is done.
#
# THE RE-LOCK RULE (relock_only: true). The ship's re-lock commit differs from the
# QA-green tree in Gemfile and Gemfile.lock alone (relock_only_diff?), so the code
# under test already went green and a red there is the gem index, not a finding.
# Its gate re-runs a first-attempt failure in ANY job, test lane or not; rules 1-3
# still hold, so a second red is still real and is never re-run.
#
# PURE: facts in, a decision out. The gh reads and the re-run live in bin/release.
module CiRerun
  module_function

  # A job name that runs a suite. Matched case-insensitively against the job's
  # check-run name ("ci / rails (2)", "engine suite (bin/release-check)",
  # "browser lane (playwright)", "test", "system-test").
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

  RERUN_CONCLUSIONS = %w[failure timed_out].freeze
  SCHEDULE_EVENT = "schedule"
  # Only a commit-triggered CI run is re-run. A workflow_dispatch run on the SHA is
  # a deploy (prod-deploy.yml, qa-deploy.yml) whose log can carry the same bundler
  # error; re-running it would re-dispatch a deploy from inside a gate.
  RERUN_EVENTS = %w[push pull_request].freeze

  # The only paths a re-lock commit may touch for the re-lock rule to apply.
  RELOCK_PATHS = %w[Gemfile Gemfile.lock].freeze

  # Does a diff of +paths+ touch nothing but Gemfile and Gemfile.lock? An empty
  # diff is not a re-lock (there is nothing to vouch for), so it answers false.
  def relock_only_diff?(paths)
    list = Array(paths).map { |p| p.to_s.strip }.reject(&:empty?)
    !list.empty? && list.all? { |p| RELOCK_PATHS.include?(p) }
  end

  # Is any commit-triggered workflow run on the SHA still unfinished? While one
  # is, a red check-run is an early read of a run that cannot yet be re-run.
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
  # the raw log never matched, the gate called the race "no gem-resolution error",
  # and the ship stopped twice for a hand re-run. So the log is unwrapped first.
  LOG_PREFIX = /^(?:[^\t\n]*\t){2}(?=\d{4}-\d\d-\d\dT)|^\d{4}-\d\d-\d\dT[\d:.]+Z ?/

  def resolution_error?(log)
    unwrap_log(log).match?(RESOLUTION_ERROR)
  end

  # PURE. The log as one line of prose: job/step/timestamp prefixes dropped, every
  # run of whitespace (the wraps included) collapsed to one space.
  def unwrap_log(log)
    log.to_s.each_line.map { |line| line.sub(LOG_PREFIX, "").sub(LOG_PREFIX, "") }.join(" ").gsub(/\s+/, " ")
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
  # failed-step log (called only when a non-test job needs the resolution check, so
  # a pure test-lane flake costs no log read). Returns
  #   { action: :rerun, run_ids: [...], reason: "..." }  or
  #   { action: :none,  reason: "..." }
  # +relock_only+: the SHA differs from the QA-green tree in Gemfile/Gemfile.lock
  # alone (see THE RE-LOCK RULE above), so any failing job qualifies.
  def plan(runs:, jobs_by_run:, log_for: ->(_id) { "" }, relock_only: false)
    runs = Array(runs)
    return { action: :none, reason: "no failed workflow run found on the SHA to re-run" } if runs.empty?

    reasons = []
    runs.each do |run|
      id = run["id"]
      label = "#{run['name'] || 'workflow'} (run #{id})"
      return { action: :none, reason: "#{label} was schedule-triggered — it does not test this commit" } if run["event"].to_s == SCHEDULE_EVENT
      return { action: :none, reason: "#{label} was #{run['event'].inspect}-triggered — only a push or pull_request CI run is re-run, never a dispatched deploy" } unless RERUN_EVENTS.include?(run["event"].to_s)
      return { action: :none, reason: "#{label} concluded #{run['conclusion']} — only a failure or a timeout is re-run" } unless RERUN_CONCLUSIONS.include?(run["conclusion"].to_s)

      attempt = run["run_attempt"].to_i
      return { action: :none, reason: "#{label} is on attempt #{attempt} — this SHA already failed that lane and was re-run; a second red is real" } if attempt != 1

      jobs = Array(jobs_by_run[id]).map(&:to_s)
      return { action: :none, reason: "#{label} names no failing job to judge" } if jobs.empty?

      if relock_only
        reasons << "#{label}: #{jobs.join(', ')} failed on attempt 1 on a re-lock commit (Gemfile/Gemfile.lock only " \
                   "past the QA-green tree)"
        next
      end

      lanes, others = jobs.partition { |job| test_lane?(job) }
      if others.any?
        return { action: :none, reason: "#{label} failed in #{others.join(', ')}, which is not a test lane and shows no gem-resolution error" } unless resolution_error?(log_for.call(id))

        reasons << "#{label}: #{others.join(', ')} hit bundler's gem-resolution error (the RubyGems CDN race)"
      end
      reasons << "#{label}: test lane#{lanes.size == 1 ? '' : 's'} #{lanes.join(', ')} failed on attempt 1" if lanes.any?
    end

    { action: :rerun, run_ids: runs.map { |r| r["id"] }, reason: reasons.join("; ") }
  end

  # Has every re-run been picked up AND concluded? A re-run only counts as the
  # second verdict once GitHub shows a later attempt that has completed; until
  # then the SHA's check-runs can still be the FIRST attempt's red, and reading
  # that as "the second red" would spend the re-run on nothing.
  def settled?(runs_now, run_ids)
    by_id = Array(runs_now).select { |r| r.is_a?(Hash) }.to_h { |r| [r["id"], r] }
    Array(run_ids).all? do |id|
      run = by_id[id]
      run && run["run_attempt"].to_i >= 2 && run["status"].to_s == "completed"
    end
  end
end
