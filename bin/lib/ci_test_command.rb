# frozen_string_literal: true

require "shellwords"
require "yaml"

# CiTestCommand — "what does CI actually run?", read from the repo's OWN
# .github/workflows/ci.yml.
#
# WHY THIS EXISTS. bin/full-suite-check is the CI-INDEPENDENT cert: the route a
# builder takes when CI's verdict is unavailable (rolio's CI can't even be read
# by bin/dor-check today) or too slow to wait for. Its whole selling point is
# "you don't need CI's verdict" — which is a LIE the moment it runs LESS OF CI'S
# RUBY SUITE than CI does. It ran `bin/rails test`, which SKIPS test/system, while
# every repo's CI runs `bin/rails db:test:prepare test test:system`. A builder could
# take the CI-independent route, go green, and have ZERO system coverage.
#
# Say the scope precisely, because a gate that OVERCLAIMS is the same bug one level
# up: this lane stands in for CI's `test` JOB (paired, in bin/full-suite-check, with
# a full rubocop — CI's `lint` job). It does NOT run CI's `scan_ruby`, `scan_js`, or
# turf-monster's `playwright` job, and it never claimed to.
#
# So the cert lane no longer hard-codes a command it hopes matches CI: it READS
# CI's, from the repo being certified, and runs it VERBATIM. A repo whose CI runs
# something narrower gets that narrower command (the rule is "run what CI runs",
# not "always add test:system"), and a repo with no ci.yml to read falls back to
# DEFAULT — which still carries the system tier, so the hole can't reopen by
# accident. The same file is the drift guard: change ci.yml and the cert follows;
# a rotted DEFAULT fails test/lib/ci_test_command_test.rb at the seam.
#
# SELECT ON THE PROPERTY, NOT THE SPELLING — the bug this file was BOUNCED for.
# The first cut picked CI's command by sniffing for the FIRST step that "mentions
# bin/rails and is one line". Every SETUP step satisfies that: park a `bin/rails
# db:test:prepare` step ahead of the real one (turf-monster's playwright job
# carries steps of exactly that shape, one job over) and the cert selects IT —
# runs it, exits 0, and stamps `[full-suite@<fp>] … green` having executed ZERO
# tests. No consumer parses the command text afterwards, so nothing downstream
# catches it. That is a cert that LIES, which is worse than no cert.
#
# The answer is not more keywords in the sniff — a blacklist of setup tasks always
# misses one. It is to decide whether a step actually RUNS TESTS (`runs_tests?`),
# from the command's STRUCTURE: parse it, find the rails/rake invocations, and ask
# whether any is handed the `test` task, a `test:*` subtask, or a test/ path.
# Setup tasks then fail by SHAPE, not by enumeration — `db:test:prepare` is a
# `db:` task, `assets:precompile` an `assets:` task, `tailwindcss:build` a
# `tailwindcss:` task. None of them IS the test task, so no setup task invented
# tomorrow can sneak through by being one nobody listed.
#
# FAIL CLOSED. The predicate is a WHITELIST of what runs tests, so an unrecognized
# test spelling reads as "no test step" — and a `test` job with run steps but no
# recognizable test step is a REFUSAL (`refusal`), never a silent pass. Loudness is
# the point: a cert that cannot find CI's test command must SAY so, so someone
# teaches the parser, instead of the gate quietly certifying nothing. (The inverse
# — a blacklist of setup tasks — fails OPEN: the one task nobody listed becomes a
# silent green.) "No ci.yml at all" is the one benign case and keeps falling back
# to DEFAULT: a full-suite superset is honest, it just isn't CI's own line.
#
# THIS LANE RUNS ONE COMMAND — so it can only stand in for a CI suite that IS one
# command. The invariant is POSITIVE and stated at WORKFLOW grain: the cert's net may
# never be SMALLER than CI's RUBY SUITE, wherever in the workflow that suite runs.
# Four shapes are a suite the lane could run only PART of, and all four REFUSE:
#   * CI's test step is a MULTI-LINE `run: |` script — that is a script, not a
#     command; the lane will not run a mangled first line and call it CI's suite.
#   * CI's `test` job runs tests in MORE THAN ONE STEP — e.g. a `bin/rails test`
#     step plus a `bin/rails db:test:prepare test:system` step, an utterly ordinary
#     CI refactor. Taking the FIRST and dropping the rest certifies green with the
#     system tier NEVER RUN: the same lie this module exists to kill, respelled.
#   * CI runs the Ruby suite in MORE THAN ONE JOB (`stray_test_steps`) — the SAME
#     split, one grain up, and the one that used to resolve in TOTAL SILENCE because
#     the reader looked at exactly `jobs.test.steps` and nowhere else.
#   * A KNOWN FOREIGN runner sits beside the rails step in the `test` job
#     (`foreign_test_steps`) — the whitelist that fails closed when SELECTING fails
#     OPEN when COUNTING, so the step was dropped and the rails one stamped green.
# Each spelling was found only after the previous one was closed. Close the SHAPE,
# not the spelling: "partially CI's suite" is not CI's suite, at ANY grain.
#
# WHAT THIS LANE DOES NOT CLAIM. It stands in for CI's RUBY suite — not for CI's every
# job. `scan_ruby` (brakeman), `scan_js` (importmap audit) and turf-monster's
# `playwright` job are tiers CI owns and this lane has never run; the cert pairs its
# command with a full `bin/rubocop` and says so. That scope is documented in
# docs/topics/testing.md, and it is what keeps a foreign runner in ANOTHER job (turf's
# playwright, TODAY) from refusing a cert lane that works.
#
# THE COMMAND SHAPE IS LOAD-BEARING — do not "simplify" it.
#   * `bin/rails test test:system` is BROKEN. `test` is a real rails COMMAND, so
#     `test:system` parses as a PATH and the run dies with
#     `LoadError: cannot load such file -- <root>/test:system`.
#   * It works in ci.yml only because the FIRST arg (`db:test:prepare`) is NOT a
#     rails command, which routes the whole line through RAKE — where `test` and
#     `test:system` are two separate tasks. KEEP db:test:prepare FIRST.
#   * That shape also self-prepares its assets: Rails skips its `test:prepare`
#     hook — the one tailwindcss-rails enhances with `tailwindcss:build`, which
#     builds the gitignored app/assets/builds/tailwind.css — whenever an argument
#     looks like a PATH. A rake-routed, path-free line fires the hook for free, so
#     a virgin worktree builds its CSS on demand with no setup step.
#   * So the working CI line carries a setup task AND the tiers in ONE command.
#     `runs_tests?` must therefore judge the whole invocation, not its first arg:
#     `bin/rails db:test:prepare test test:system` RUNS TESTS; `bin/rails
#     db:test:prepare` alone does not.
module CiTestCommand
  # The fallback when a repo has no ci.yml to read. Every Rails repo in the
  # ecosystem (hub, turf-monster, rolio) runs exactly this today; pinned against
  # the hub's real ci.yml by test/lib/ci_test_command_test.rb.
  DEFAULT = "bin/rails db:test:prepare test test:system"

  WORKFLOW = File.join(".github", "workflows", "ci.yml")

  # Executables whose ARGUMENTS are rails/rake tasks. `bin/rails`, `rails`,
  # `bin/rake`, `rake` — compared by BASENAME so the path can't hide them.
  RAILS_ENTRYPOINTS = %w[rails rake].freeze

  # Shell operators that end one invocation and start the next inside a single
  # step (`bin/rails db:test:prepare && bin/rails test`).
  SHELL_SEPARATORS = %w[&& || | ; &].freeze

  # A leading `FOO=bar` env assignment: `RAILS_ENV=test bin/rails test`.
  ENV_ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

  # The ONE `test:`-prefixed task that RUNS NOTHING: rails' asset/db prep hook
  # (the one tailwindcss-rails enhances). Excluded by name because it is the sole
  # structural exception to "a `test:` task runs tests".
  PREPARE_HOOK = "test:prepare"

  # --- the property --------------------------------------------------------------

  # Is this token a rails/rake task (or path) that RUNS TESTS?
  #
  # `test` — the rails test command / rake test task
  # `test:system`, `test:all`, … — its subtasks (any `test:` task but the hook)
  # `test/models/user_test.rb`, `test/integration` — a path INTO the suite
  #
  # Note what is NOT here: no list of setup tasks. `db:test:prepare` fails because
  # it is a `db:` task, not because it was enumerated.
  def self.test_task?(token)
    token = token.to_s
    return false if token == PREPARE_HOOK

    token == "test" || token.start_with?("test:", "test/")
  end

  # Does this command text RUN TESTS? True when ANY rails/rake invocation in it —
  # across newlines and &&/||/;/| chains — is handed a test task.
  def self.runs_tests?(command)
    invocations(command).any? { |tokens| invocation_runs_tests?(tokens) }
  end

  # Every command invocation in the text, as token arrays. A `run: |` block is a
  # LIST of commands (split on newlines), and each line may chain several more
  # (split on the shell separators).
  def self.invocations(command)
    command.to_s.lines.flat_map { |line| split_on_separators(safe_split(line)) }
  end

  # Does this ONE invocation run tests?
  def self.invocation_runs_tests?(tokens)
    args = rails_args(tokens)
    return false if args.nil?

    # The task list is the LEADING run of non-flag arguments. Stopping at the first
    # flag is what keeps `bin/rails runner -e test e2e/seed.rb` (turf's playwright
    # job) from reading as a test run: that `test` is the VALUE of `-e`, the
    # RAILS_ENV, not a task.
    args.take_while { |arg| !arg.start_with?("-") }.any? { |arg| test_task?(arg) }
  end

  # The arguments this invocation hands to rails/rake, or nil when it does not
  # invoke rails/rake at all (`sudo apt-get …`, `npm test`, `yarn build`).
  def self.rails_args(tokens)
    exe, args = entrypoint(tokens)
    return nil unless exe && RAILS_ENTRYPOINTS.include?(exe)

    args
  end

  # An invocation's [executable BASENAME, arguments], after stripping the noise that
  # hides the real executable: leading `FOO=bar` env assignments and a `bundle exec`
  # prefix. Shared by the rails probe and the foreign-runner sniff so both see the
  # same executable — `bundle exec rspec` is rspec, `RAILS_ENV=test bin/rails` is rails.
  def self.entrypoint(tokens)
    tokens = tokens.drop_while { |token| ENV_ASSIGNMENT.match?(token) }
    tokens = tokens.drop(2) if tokens.first(2).map { |t| File.basename(t) } == %w[bundle exec]

    exe = tokens.first
    return [nil, []] unless exe

    [File.basename(exe), tokens.drop(1)]
  end

  # --- the foreign runners --------------------------------------------------------

  # Test runners that are NOT rails. Recognized ONLY to ADD A REFUSAL — never to
  # SELECT, and never to widen what the lane runs.
  #
  # SAFE POLARITY, and do not invert it. The strict invariant ("refuse on any run
  # step we cannot classify") is NOT implementable at step grain: the HUB'S OWN
  # `test` job carries a multi-line chromedriver-evict script that runs no tests and
  # never will be classifiable, so the strict rule refuses the hub on every cert.
  # So the sniff is a WHITELIST used in the loud direction only:
  #   * a runner nobody listed → invisible, i.e. exactly TODAY'S behavior (no worse);
  #   * a runner we DO know     → a refusal (louder).
  # Used to SELECT, the same whitelist would fail OPEN — the one runner nobody listed
  # becomes a silent green, which is the bug this module exists to kill.
  # Executables that ARE a test run, whatever their arguments.
  BARE_TEST_RUNNERS = %w[rspec pytest jest vitest mocha cucumber ava tap].freeze
  # Executables that run tests only under a specific SUBCOMMAND — `playwright test`
  # runs the suite, `playwright install` fetches browsers. The distinction is not
  # pedantic: turf-monster's CI runs BOTH.
  SUBCOMMAND_TEST_RUNNERS = { "playwright" => "test", "cypress" => "run" }.freeze
  NODE_PACKAGE_MANAGERS = %w[npm yarn pnpm bun].freeze
  # `npx <bin> …`, and `pnpm dlx <bin> …` / `npm exec <bin> …` — all of them are an
  # invocation OF `<bin>`. Unwrap the shim and judge what it actually runs.
  NODE_RUNNER_SHIMS = %w[npx].freeze
  NODE_EXEC_SUBCOMMANDS = %w[dlx exec].freeze

  # Does this command text run tests with a KNOWN non-rails runner?
  def self.foreign_test_runner?(command)
    invocations(command).any? { |tokens| invocation_runs_foreign_tests?(tokens) }
  end

  # Judged on the LEADING (pre-flag) arguments, like the rails probe — so `npm test --
  # --shard=1/3` reads as the `test` script, while the SETUP spellings of the very same
  # executables stay SILENT: `npm ci`, `npm install`, `npm run build`, `go build`, and
  # `npx playwright install --with-deps chromium` (which turf-monster's CI really runs,
  # one step above its real playwright call). Sniffing the EXECUTABLE alone would refuse
  # every repo in the ecosystem that installs its JS dependencies.
  def self.invocation_runs_foreign_tests?(tokens)
    exe, args = entrypoint(tokens)
    return false if exe.nil?

    # `npx playwright test` is an invocation of playwright — unwrap the shim and judge
    # what it actually runs, so `npx playwright install` cannot read as a test run.
    return invocation_runs_foreign_tests?(args) if NODE_RUNNER_SHIMS.include?(exe)

    leading = args.take_while { |arg| !arg.start_with?("-") }

    case exe
    when *BARE_TEST_RUNNERS then true
    when *SUBCOMMAND_TEST_RUNNERS.keys then leading.include?(SUBCOMMAND_TEST_RUNNERS[exe])
    when *NODE_PACKAGE_MANAGERS then node_package_manager_runs_tests?(args, leading)
    when "make", "just" then leading.any? { |arg| test_script_name?(arg) }
    when "go", "cargo", "mix" then leading.first == "test"
    else false
    end
  end

  # `npm test`, `yarn test:e2e` — a test SCRIPT; but `pnpm dlx playwright test` and
  # `npm exec jest` are shims around another executable, so unwrap those too.
  def self.node_package_manager_runs_tests?(args, leading)
    return invocation_runs_foreign_tests?(args.drop(1)) if NODE_EXEC_SUBCOMMANDS.include?(leading.first)

    node_test_script?(leading)
  end

  # `npm test`, `npm run test`, `yarn test:e2e`, `pnpm run test:ci` — but NOT `npm ci`,
  # `npm install`, `npm run build`.
  def self.node_test_script?(leading)
    script = leading.first == "run" ? leading[1] : leading.first
    test_script_name?(script)
  end

  def self.test_script_name?(name)
    name.to_s == "test" || name.to_s.start_with?("test:")
  end

  # Shellwords, but an unbalanced-quote line proves nothing rather than raising
  # inside a cert.
  def self.safe_split(line)
    Shellwords.split(line)
  rescue ArgumentError
    []
  end

  def self.split_on_separators(tokens)
    tokens.each_with_object([[]]) { |token, groups|
      SHELL_SEPARATORS.include?(token) ? groups << [] : groups.last << token
    }.reject(&:empty?)
  end

  # --- reading ci.yml ------------------------------------------------------------

  # The job whose command this lane stands in for. The cert runs ONE command, so it
  # can only ever be ONE job's — and this is the one every repo in the ecosystem
  # names. What the cert does NOT get to do is let the RUBY SUITE quietly leave this
  # job (see `stray_test_steps`).
  TEST_JOB = "test"

  # EVERY job in the workflow, as job name => its `run:` strings. nil when there is
  # nothing to read (no ci.yml, unparseable YAML, no `jobs:` map).
  #
  # Jobs with no `steps:` are SKIPPED, not errors: a `uses:` reusable-workflow job
  # has none, and a null job body is legal YAML. A cert may not raise on either.
  def self.jobs(root)
    path = File.join(root.to_s, WORKFLOW)
    return nil unless File.file?(path)

    ci = YAML.safe_load_file(path, aliases: true)
    jobs = ci.is_a?(Hash) ? ci["jobs"] : nil
    return nil unless jobs.is_a?(Hash)

    jobs.each_with_object({}) do |(name, job), out|
      steps = job.is_a?(Hash) ? job["steps"] : nil
      next unless steps.is_a?(Array)

      out[name.to_s] = steps.filter_map { |step| step["run"].to_s if step.is_a?(Hash) && step["run"] }
                            .reject { |run| run.strip.empty? }
    end
  rescue StandardError
    nil # an unreadable/odd ci.yml must fall back, never raise inside a cert
  end

  # The `run:` strings of the ci.yml `test` job, or nil when there is no job to
  # read (no ci.yml, no `test` job, unparseable YAML). nil means "no information";
  # [] means "a test job that runs no commands".
  def self.run_steps(root)
    jobs = jobs(root)
    return nil unless jobs.is_a?(Hash)

    jobs[TEST_JOB]
  end

  # Test steps that run the RUBY SUITE somewhere OTHER than the `test` job — as
  # [job, run] pairs, so a refusal can NAME what it saw.
  #
  # THE JOB-GRAIN HOLE. The resolver read exactly `jobs.test.steps`, so the very same
  # suite split that REFUSES across STEPS resolved QUIETLY across JOBS:
  #
  #     jobs:
  #       test:         { steps: [ { run: bin/rails test } ] }
  #       system_test:  { steps: [ { run: bin/rails db:test:prepare test:system } ] }
  #
  # — an utterly ordinary CI refactor (parallelize the slow tier). `jobs.test` still
  # holds ONE single-line rails test step, so every step-grain guard passes, and the
  # cert certifies `bin/rails test` GREEN with the system tier NEVER RUN, one job over,
  # entirely unread. That is the lying cert this module exists to kill, in a THIRD
  # spelling — after "picked a setup step" and "dropped a sibling step".
  #
  # So the invariant is stated POSITIVELY and at WORKFLOW grain: the cert's net may
  # not be SMALLER than CI's Ruby suite, wherever in the workflow that suite runs.
  # Any Ruby test step outside the job we stand in for means the suite is SPLIT and
  # this one-command lane cannot honestly stand in for it — REFUSE, loudly, naming
  # the job and the step, rather than resolve to the narrower half.
  #
  # WHY THIS DOES NOT REFUSE turf-monster TODAY — the live constraint, and the reason
  # `runs_tests?` had to be structural before this scan could exist. turf's playwright
  # job is a second TEST-BEARING job right now, and it must keep resolving:
  #   * `npm test -- --shard=1/3`                              → not rails (a foreign
  #     runner in ANOTHER job is a tier this lane never claimed — see docs/topics/
  #     testing.md — not a split of the Ruby suite);
  #   * `bin/rails runner -e test e2e/seed.rb`                 → `test` is the VALUE
  #     of `-e` (the RAILS_ENV), not a task;
  #   * `bin/rails db:test:prepare` / `bin/rails tailwindcss:build` → setup, by SHAPE.
  # A substring sniff for "test" would refuse turf's cert lane on every run. A guard
  # that bricks a working lane is worse than the latent bug it closes.
  def self.stray_test_steps(root)
    jobs = jobs(root)
    return [] unless jobs.is_a?(Hash)

    jobs.reject { |name, _runs| name == TEST_JOB }
        .flat_map { |name, runs| runs.select { |run| runs_tests?(run) }.map { |run| [name, run.strip] } }
  end

  # Steps of the `test` job that run tests with a KNOWN FOREIGN runner and that this
  # lane would therefore DROP — `npx playwright test` or `bundle exec rspec` sitting
  # beside the rails step.
  #
  # THE COUNT'S BLIND SPOT. The set count is derived from `runs_tests?`, a whitelist —
  # and a whitelist fails OPEN when COUNTING. Selection fails closed correctly (an
  # unrecognized spelling refuses, never gets picked), but the COUNT silently drops
  # what it does not recognize: `bin/rails db:test:prepare test test:system` + `npx
  # playwright test` counts ONE test step, resolves the rails one, and stamps GREEN
  # with playwright never run.
  #
  # Steps that ALREADY run rails tests are excluded deliberately: chained into ONE
  # step (`bin/rails test test:system && npx playwright test`) the lane runs the whole
  # string VERBATIM, so nothing is dropped. The refusal is about steps the lane would
  # DROP — not about how many runners appear.
  def self.foreign_test_steps(root)
    steps = run_steps(root)
    return [] unless steps.is_a?(Array)

    steps.map(&:strip).select { |run| foreign_test_runner?(run) && !runs_tests?(run) }
  end

  # EVERY step in CI's `test` job that RUNS TESTS — the selection SET, not the first
  # hit, and NOT pre-filtered to the ones this lane happens to be able to run. nil =
  # no job to read; [] = a test job we recognize no tests in; ONE entry = the only
  # shape this lane can stand in for; MORE THAN ONE = CI runs its suite across
  # several commands, and a one-command lane can only ever run PART of it.
  #
  # Each step is judged by what it DOES (`runs_tests?`), not by step name and not by
  # a `bin/rails` mention — so neither renaming a step nor parking a setup step ahead
  # of the real one can blind or hijack the resolver.
  #
  # Multi-line steps are counted HERE and rejected in `for_root`, deliberately: a
  # script is a test step this lane cannot run, and pretending it isn't one would
  # let a single-line step next to it resolve while the script is silently dropped —
  # the drop being the whole bug. Count the suite first; judge runnability second.
  def self.test_steps(root)
    steps = run_steps(root)
    return nil unless steps.is_a?(Array)

    steps.map(&:strip).select { |run| runs_tests?(run) }
  end

  # The ONE command the repo's ci.yml `test` job uses to RUN TESTS, or nil when there
  # is none the cert lane can run VERBATIM.
  #
  # The invariant is positive and singular: CI runs its tests in EXACTLY ONE step,
  # and that step is ONE line. Anything else is nil — which `refusal` turns into a
  # loud abort. nil therefore covers "found none", "found a script", and "found
  # SEVERAL", and the several case is a refusal, not a pick.
  #
  # That last one is why this method exists in this shape. It used to `.find` the
  # first test step and silently drop the rest, so an utterly ordinary CI refactor —
  #
  #     - name: Run tests
  #       run: bin/rails test
  #     - name: Run system tests
  #       run: bin/rails db:test:prepare test:system
  #
  # — resolved to `bin/rails test` and certified GREEN with ZERO system coverage: the
  # exact lie this module exists to kill, in a different spelling. It is the same
  # failure as the multi-line script (a suite the lane can only run PART of), and it
  # failed OPEN where the script case already failed closed. Both refuse now.
  # The full invariant, in one place. CI's Ruby suite must run in EXACTLY ONE step, of
  # ONE line, in ONE job — and nothing this lane would DROP may sit beside it. Every
  # other shape is a suite the lane could only run PART of, and `refusal` turns each
  # into a loud abort.
  def self.for_root(root)
    steps = test_steps(root)
    return nil unless steps.is_a?(Array) && steps.length == 1
    return nil unless single_line?(steps.first)
    return nil unless foreign_test_steps(root).empty? # a runner beside it, in this job
    return nil unless stray_test_steps(root).empty?   # the suite, split across JOBS

    steps.first
  end

  # What the cert lane should run for this repo: CI's command, else the default.
  def self.resolve(root)
    for_root(root) || DEFAULT
  end

  # The LOUD half. Returns an operator-facing message when this repo has a ci.yml
  # `test` job we can read but CANNOT honestly stand in for — and nil when the cert
  # may proceed. The caller aborts on it (bin/full-suite-check), because a cert that
  # cannot find CI's test command must refuse, not quietly certify something else.
  #
  # Deliberately silent for a repo with NO ci.yml: DEFAULT is a full-suite superset
  # there, which is honest — it just isn't CI's own line.
  def self.refusal(root)
    steps = run_steps(root)
    return nil unless steps.is_a?(Array) && steps.any?
    return nil if for_root(root)

    path = File.join(root.to_s, WORKFLOW)
    tests = test_steps(root)
    strays = stray_test_steps(root)
    foreign = foreign_test_steps(root)

    if tests.length > 1
      "#{path}'s `test` job runs its tests in #{tests.length} STEPS (#{tests.map { |run| label(run) }.inspect}) " \
        "and this cert lane runs ONE command — it will not run one of them and call it CI's suite. Certifying " \
        "on `#{label(tests.first)}` alone is exactly how a green cert lands with a whole tier NEVER RUN. Set " \
        "FULL_SUITE_TEST_CMD to the single command that runs CI's suite for this repo, or collapse the CI " \
        "steps into one."
    elsif tests.length == 1 && !single_line?(tests.first)
      "#{path}'s `test` job runs its tests from a MULTI-LINE `run:` script, and this cert lane runs ONE " \
        "command — it will not run a mangled first line and call it CI's suite. Set FULL_SUITE_TEST_CMD to " \
        "the single command that runs CI's suite for this repo, or collapse the CI step to one line."
    elsif strays.any?
      # The JOB-grain split. Name every place the Ruby suite runs, so the operator can
      # see the net this lane would have cast against the one CI casts.
      seen = (tests.map { |run| "#{TEST_JOB}: #{label(run)}" } +
              strays.map { |job, run| "#{job}: #{label(run)}" })
      "#{path} runs its Ruby test suite in MORE THAN ONE JOB (#{seen.inspect}). This cert lane runs ONE " \
        "command and reads only the `#{TEST_JOB}` job, so it would certify on that job alone and leave CI's " \
        "other test job(s) NEVER RUN — a green cert with a whole tier missing is precisely the lie this lane " \
        "exists to kill. Collapse CI's Ruby suite into one job, or set FULL_SUITE_TEST_CMD to the single " \
        "command that runs all of it."
    elsif foreign.any?
      "#{path}'s `#{TEST_JOB}` job runs tests with ANOTHER RUNNER beside its rails step " \
        "(#{foreign.map { |run| label(run) }.inspect}), and this cert lane runs ONE command — certifying on " \
        "`#{label(tests.first)}` alone silently DROPS it, which is how a green cert lands with a whole tier " \
        "NEVER RUN. Set FULL_SUITE_TEST_CMD to the single command that runs both, chain them into one step, " \
        "or move the other runner into its own job (this lane stands in for CI's Ruby suite, not its every " \
        "tier — see docs/topics/testing.md)."
    else
      "#{path}'s `test` job has #{steps.length} `run` step(s) and NONE of them runs tests " \
        "(#{steps.map { |run| label(run) }.inspect}). This cert stands in for CI, so it " \
        "will not certify a command that runs no tests — that is how a green cert comes to mean nothing. Add " \
        "the test step to CI, or set FULL_SUITE_TEST_CMD to the command that runs this repo's suite."
    end
  end

  # A step's one-line name for an operator-facing message: multi-line scripts are
  # shown by their first line with an ellipsis, so a refusal stays readable and the
  # operator can still tell WHICH step it means.
  def self.label(run)
    first = run.to_s.strip.lines.first.to_s.strip
    single_line?(run) ? first : "#{first} …"
  end

  # Does this command run the SYSTEM tier?
  #
  # STRUCTURAL and EXACT, like the rest of this parser: the `test:system` TASK, or a
  # path into test/system. `bin/rails test test/system` runs the tier too, and a
  # substring probe for "test:system" misses that form entirely.
  #
  # This is the "what tier does this command run?" answer, and it is deliberately not
  # the whole BROWSER GUARD. Being structural, it sees no WRAPPER form (`docker compose
  # run web bin/rails test:system` — the executable is docker, not rails), and a guard
  # that must fail SAFE cannot afford that miss. bin/lib/system_test_browser.rb
  # therefore UNIONS this with a textual probe; the asymmetry that forces the union is
  # argued there. Keep this half exact — the safety belongs with the guard, not here.
  def self.system_tier?(cmd)
    invocations(cmd).any? do |tokens|
      args = rails_args(tokens)
      next false if args.nil?

      args.take_while { |arg| !arg.start_with?("-") }
          .any? { |arg| arg == "test:system" || arg == "test/system" || arg.start_with?("test/system/") }
    end
  end

  def self.single_line?(command)
    command.to_s.strip.lines.length == 1
  end
end
