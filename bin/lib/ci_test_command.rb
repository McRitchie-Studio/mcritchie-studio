# frozen_string_literal: true

require "shellwords"
require "yaml"

# CiTestCommand — "what does CI actually run?", read from the repo's OWN
# .github/workflows/ci.yml.
#
# WHY THIS EXISTS. bin/full-suite-check is the CI-INDEPENDENT cert: the route a
# builder takes when CI's verdict is unavailable (rolio's CI can't even be read
# by bin/dor-check today) or too slow to wait for. Its whole selling point is
# "you don't need CI's verdict" — which is a LIE the moment it tests LESS than
# CI. It ran `bin/rails test`, which SKIPS test/system, while every repo's CI
# runs `bin/rails db:test:prepare test test:system`. A builder could take the
# CI-independent route, go green, and have ZERO system coverage.
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
    tokens = tokens.drop_while { |token| ENV_ASSIGNMENT.match?(token) }
    tokens = tokens.drop(2) if tokens.first(2).map { |t| File.basename(t) } == %w[bundle exec]

    exe = tokens.first
    return nil unless exe && RAILS_ENTRYPOINTS.include?(File.basename(exe))

    tokens.drop(1)
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

  # The `run:` strings of the ci.yml `test` job, or nil when there is no job to
  # read (no ci.yml, no `test` job, unparseable YAML). nil means "no information";
  # [] means "a test job that runs no commands".
  def self.run_steps(root)
    path = File.join(root.to_s, WORKFLOW)
    return nil unless File.file?(path)

    ci = YAML.safe_load_file(path, aliases: true)
    steps = ci.dig("jobs", "test", "steps")
    return nil unless steps.is_a?(Array)

    steps.filter_map { |step| step["run"].to_s if step.is_a?(Hash) && step["run"] }
         .reject { |run| run.strip.empty? }
  rescue StandardError
    nil # an unreadable/odd ci.yml must fall back, never raise inside a cert
  end

  # The command the repo's ci.yml `test` job uses to RUN TESTS, or nil when there
  # is none the cert lane can run verbatim.
  #
  # Located by what it DOES (`runs_tests?`), not by step name and not by the first
  # mention of `bin/rails` — so neither renaming the step nor parking a setup step
  # ahead of it can blind or hijack the resolver.
  #
  # A multi-line `run: |` block is deliberately NOT selectable: that is a SCRIPT,
  # and the cert lane runs ONE command string — running a mangled first line and
  # calling it CI's suite is the very failure this module exists to prevent. When
  # CI's ONLY test step is a script, `refusal` says so out loud.
  def self.for_root(root)
    steps = run_steps(root)
    return nil unless steps.is_a?(Array)

    steps.map(&:strip)
         .select { |run| single_line?(run) }
         .find { |run| runs_tests?(run) }
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

    if steps.any? { |run| runs_tests?(run) }
      "#{path}'s `test` job runs its tests from a MULTI-LINE `run:` script, and this cert lane runs ONE " \
        "command — it will not run a mangled first line and call it CI's suite. Set FULL_SUITE_TEST_CMD to " \
        "the single command that runs CI's suite for this repo, or collapse the CI step to one line."
    else
      "#{path}'s `test` job has #{steps.length} `run` step(s) and NONE of them runs tests " \
        "(#{steps.map { |run| run.strip.lines.first.to_s.strip }.inspect}). This cert stands in for CI, so it " \
        "will not certify a command that runs no tests — that is how a green cert comes to mean nothing. Add " \
        "the test step to CI, or set FULL_SUITE_TEST_CMD to the command that runs this repo's suite."
    end
  end

  # Does this command run the SYSTEM tier (and therefore need a browser)?
  #
  # Structural, like the rest: the `test:system` TASK, or a path into test/system —
  # `bin/rails test test/system` runs the tier too, and a substring probe for
  # "test:system" misses it, which costs the caller its browser guard.
  #
  # (bin/lib/system_test_browser.rb carries a substring twin of this predicate for
  # the release gate; the two agree on every command either repo's CI actually runs.)
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
