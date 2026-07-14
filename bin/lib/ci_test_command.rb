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
# So the cert lane no longer hard-codes a command it hopes matches CI: it READS
# CI's, from the repo being certified, and runs it VERBATIM. A repo whose CI runs
# something narrower gets that narrower command (the rule is "run what CI runs",
# not "always add test:system"), and a repo with no ci.yml to read falls back to
# DEFAULT — which still carries the system tier, so the hole can't reopen by
# accident. The same file is the drift guard: change ci.yml and the cert follows;
# a rotted DEFAULT fails test/lib/ci_test_command_test.rb at the seam.
#
# ============================================================================
# THE ONE INVARIANT. Everything below is in service of it, and nothing else:
#
#     THE CERT MAY STAND IN FOR CI ONLY WHEN IT CAN SEE CI'S WHOLE RUBY SUITE
#     AND RUN ALL OF IT IN ITS ONE COMMAND.
#
# It is POSITIVE (a property the workflow must HAVE, not a list of shapes it must
# not have) and it decides the two error directions asymmetrically:
#
#   * Anything this parser CANNOT SEE INTO is, by definition, not something it has
#     proven runs no tests. It REFUSES — loudly, naming what it could not read.
#     An over-fire costs an operator one message and a one-line fix (teach the
#     parser, or set FULL_SUITE_TEST_CMD).
#   * An under-fire is a GREEN CERT WITH A TIER NEVER RUN. That is the lie this
#     module exists to kill, and it has now been shipped three times in three
#     different spellings.
#
# ============================================================================
# READ THIS BEFORE YOU "SIMPLIFY" ANY PROBE BELOW — the history is the argument.
#
# This guard has been defeated in SEVEN spellings, and every single one is the same
# bug: THE PARSER LOOKED AT A NARROWER SLICE OF CI THAN CI ACTUALLY RUNS. Each round
# closed the spelling that had just been found, so the next pair of eyes found the
# next spelling. The spellings, in the order they were found:
#
#   1. a SETUP step parked ahead of the real one was SELECTED (`db:test:prepare`);
#   2. the suite SPLIT ACROSS TWO STEPS of the test job — the first was picked, the
#      rest silently dropped;
#   3. a KNOWN FOREIGN runner (`npx playwright test`) beside the rails step — counted
#      by a whitelist, so it was silently dropped;
#   4. the suite SPLIT ACROSS JOBS — `jobs.test.steps` was the only thing read;
#   5. a WRAPPER hid the rails invocation from the parser (`docker compose run web
#      bin/rails test:system`) — the executable is `docker`, so the probe said "no
#      rails invocation here";
#   6. a job with NO `steps:` (a job-level `uses:` reusable workflow, a composite
#      action, an unreadable job body) was SKIPPED as if skipping were safe;
#   7. an INDIRECTION the parser never followed — `make test`, `./bin/ci-system`,
#      `sh -c "bin/rails test:system"` — or the suite living in a SIBLING PR-gating
#      workflow file the parser never opened.
#
# So the question this file asks changed. It used to be:
#
#     "Is this step, structurally, a bare rails test invocation?"   ← a SPELLING
#
# It is now:
#
#     "Could this job be running the Ruby suite AT ALL — and if I cannot tell,
#      do I refuse?"                                                ← a PROPERTY
#
# The three probes that answer it, and why each exists:
#
#   * `runs_ruby_suite?` — MAXIMALLY SENSITIVE, because it answers "how big is CI's
#     net?" It is wrapper-transparent (a rails invocation ANYWHERE in the line, not
#     just at position 0 — `docker …`/`ssh …`/`timeout …`/`sudo …` are just tokens
#     that precede it), it recurses into QUOTED inner commands (`sh -c "…"`), it
#     FOLLOWS indirections it can read (a repo-local script; a Makefile target), and
#     it unions a TEXTUAL marker scan on top of all of that. Over-firing here costs
#     a message; under-firing here is the lie.
#   * `runnable_here?` — MAXIMALLY CONSERVATIVE, because it answers a different
#     question: "can this lane run that step VERBATIM as its one command?" One line,
#     a DIRECT rails/rake invocation. A step the lane can SEE but cannot RUN
#     (`docker compose run web bin/rails test:system`) is a REFUSAL, never a silent
#     narrowing to something else.
#   * `opaque_units` — the FAIL-CLOSED half. A job with no readable `steps:`, or a
#     step whose `uses:` action this parser has not proven inert, is NOT a job proven
#     to run no tests. It refuses, naming it.
#
# Conflating the first two is what produced spellings 5 and 6: one probe was asked
# both "does CI run tests here?" and "can I run this?", and the answer that keeps the
# lane WORKING (be strict) is the opposite of the answer that keeps it HONEST (be
# sensitive). Keep them separate.
#
# ============================================================================
# WHAT THIS LANE DOES NOT CLAIM — say the scope precisely, because a gate that
# OVERCLAIMS is the same bug one level up, and the docs must match this list exactly
# (docs/topics/testing.md, docs/agents/modules/gates/g1-cert.md).
#
#   * It stands in for CI's RUBY suite, not CI's every job. `scan_ruby` (brakeman),
#     `scan_js` (importmap audit) and turf-monster's `playwright` job are tiers CI
#     owns and this lane has never run; the cert pairs its command with a full
#     `bin/rubocop` (CI's `lint` job) and says so. That scope is ALSO what keeps a
#     foreign runner in ANOTHER job (turf's playwright, TODAY) from refusing a cert
#     lane that works.
#   * It reads the repo's PR-GATING workflows (`on: pull_request`). A workflow that
#     does NOT gate PRs (turf-monster's scheduled devnet-nightly.yml) is not part of
#     the verdict this lane stands in for, and is not read.
#   * A repo with NO ci.yml is the one benign case: there is no CI command to stand
#     in for, so the lane runs the DEFAULT — a full-suite SUPERSET for a stock Rails
#     repo, honest, just not CI's own line. studio-engine is the live example (its CI
#     is consumer-ci.yml, which runs the CONSUMER apps' suites in a checked-out
#     sibling — a suite this lane cannot run at all; gems are verified through their
#     consumers, docs/agents/modules/testing.md).
#   * THE RESIDUE, NAMED. Three things can still hide a Ruby suite from this parser,
#     and it does not pretend otherwise: an executable that is neither a known runner
#     nor a readable file in this repo (an arbitrary global tool); a third-party
#     `uses:` action whose steps live in another repo — which is why an action must be
#     PROVEN INERT (KNOWN_INERT_ACTIONS) or it refuses; and a ci.yml so malformed that
#     YAML cannot parse it (that falls back to the DEFAULT superset, which cannot
#     shrink the net for a stock Rails repo).
#
# ============================================================================
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
#     The probes must therefore judge the whole invocation, not its first arg:
#     `bin/rails db:test:prepare test test:system` RUNS TESTS; `bin/rails
#     db:test:prepare` alone does not.
module CiTestCommand
  # The fallback when a repo has no ci.yml to read. Every Rails repo in the
  # ecosystem (hub, turf-monster, rolio, chain-ops) runs exactly this today; pinned
  # against the hub's real ci.yml by test/lib/ci_test_command_test.rb.
  DEFAULT = "bin/rails db:test:prepare test test:system"

  # The workflow this lane STANDS IN FOR (resolution). Its existence is also the
  # switch for the whole net check: no ci.yml → no CI command to stand in for → the
  # DEFAULT superset, silently (see `scan`).
  WORKFLOW = File.join(".github", "workflows", "ci.yml")
  WORKFLOW_DIR = File.join(".github", "workflows")

  # The job whose command this lane runs. The cert runs ONE command, so it can only
  # ever be ONE job's — and this is the one every Rails repo in the ecosystem names.
  # The NAME is only an ANCHOR for which command to RUN; every JUDGMENT below is made
  # on what a step DOES. A Ruby suite that runs anywhere else — another job, another
  # PR-gating workflow — does not get to be invisible because of what it is CALLED:
  # it REFUSES (`suite_steps`).
  TEST_JOB = "test"

  # The triggers that make a workflow part of the PR verdict this lane stands in for.
  # turf-monster's devnet-nightly.yml (schedule + workflow_dispatch) is deliberately
  # not one of them.
  PR_TRIGGERS = %w[pull_request pull_request_target].freeze

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

  # The TEXTUAL half of the suite probe, unioned on top of the structural one for the
  # same reason the browser guard unions it (bin/lib/system_test_browser.rb): a probe
  # that must FAIL SAFE cannot afford a miss, and these two probes miss different
  # things. Scoped to the SYSTEM-tier spellings on purpose — sniffing the bare word
  # `test` would refuse turf-monster's cert lane on every run (its playwright job is
  # thick with the word), while `test:system` / `test/system` appear in all four live
  # ci.yml files ONLY inside the real test step. Zero live over-fire, and it catches
  # any spelling that hides the rails token itself.
  SUITE_MARKERS = %w[test:system test/system].freeze

  # Actions PROVEN INERT by inspection — they set up an environment or move
  # artifacts; none of them runs this repo's Ruby suite. Matched on owner/repo, so a
  # Dependabot version bump (`@v1` → `@v2`) does not fire.
  #
  # THE POLARITY IS THE POINT, and it is the opposite of the foreign-runner whitelist
  # (`BARE_TEST_RUNNERS`, below) — read both before changing either:
  #   * an action NOT on this list is a step whose contents live in ANOTHER REPO and
  #     which this parser therefore CANNOT PROVE runs no tests → it REFUSES;
  #   * a runner not on the foreign list is a step INSIDE a job we can already see,
  #     and refusing on it is unimplementable (see BARE_TEST_RUNNERS) → it stays
  #     silent.
  # Both fail in the SAFE direction for their grain. Adding a new action to a repo's
  # ci.yml therefore costs one line HERE, on purpose: a human decides "does this
  # action run tests?" once, instead of the cert assuming "no" forever.
  KNOWN_INERT_ACTIONS = %w[
    actions/checkout
    actions/cache
    actions/setup-node
    actions/setup-python
    actions/upload-artifact
    actions/download-artifact
    ruby/setup-ruby
    browser-actions/setup-chrome
  ].freeze

  # An indirection this parser FOLLOWS rather than guesses at (`repo_script_body`,
  # `make_recipe`). A file in THIS repo is readable, so read it.
  MAKEFILES = %w[Makefile makefile GNUmakefile].freeze
  # Bound the recursion: quoted inner commands, scripts that call scripts, Makefile
  # targets that call scripts. Depth 3 covers every real shape; the cap is what keeps
  # a cyclic script (`bin/ci` calling itself) from hanging a cert.
  MAX_INDIRECTION_DEPTH = 3
  # A "script" the cert will read and probe. Bigger than this, or not text, and it is
  # not something we can read — see THE RESIDUE, NAMED.
  SCRIPT_SIZE_CAP = 64 * 1024

  # --- the suite probe: does this text RUN THE RUBY SUITE? -------------------------
  #
  # SENSITIVE BY DESIGN. This answers "how big is CI's net", so every miss is a green
  # cert with a tier never run. It says yes on FOUR independent grounds, unioned:
  #
  #   1. a rails/rake invocation ANYWHERE in the line, handed a test task
  #      (wrapper-transparent: `docker compose run web bin/rails test:system`);
  #   2. a QUOTED inner command that itself runs the suite (`sh -c "bin/rails test"`);
  #   3. an INDIRECTION we can read: a repo-local script, or a Makefile target;
  #   4. the TEXTUAL system-tier markers, whatever the structure (`SUITE_MARKERS`).
  #
  # `root` is optional only so the pure-text probes stay callable without a repo;
  # pass it wherever you have it, or grounds 3 goes blind.
  def self.runs_ruby_suite?(command, root = nil, depth = 0)
    text = command.to_s
    return true if SUITE_MARKERS.any? { |marker| text.include?(marker) }

    invocations(text).any? { |tokens| invocation_runs_suite?(tokens, root, depth) }
  end

  def self.invocation_runs_suite?(tokens, root, depth)
    return true if rails_invocation_anywhere?(tokens)
    return false if depth >= MAX_INDIRECTION_DEPTH

    return true if quoted_inner_command_runs_suite?(tokens, root, depth)

    indirection_runs_suite?(tokens, root, depth)
  end

  # A rails/rake invocation ANYWHERE in the token stream — the wrapper fix, stated as
  # a property instead of a list of wrappers.
  #
  # The old probe asked "is the FIRST token rails?", so ANY prefix hid the suite from
  # it: `docker compose run web …`, `ssh host …`, `timeout 30m …`, `sudo -u ci …`,
  # `nix-shell --run …`. Enumerating wrappers would have missed the next one — there
  # is no end to that list. So we do not enumerate: a wrapper is just TOKENS THAT
  # PRECEDE a command, and a rails invocation is a rails invocation wherever it sits.
  # The task list is still the LEADING run of non-flag args AFTER the entrypoint, which
  # is what keeps `bin/rails runner -e test e2e/seed.rb` (turf's playwright job) from
  # reading as a test run: that `test` is the VALUE of `-e`, the RAILS_ENV, not a task.
  def self.rails_invocation_anywhere?(tokens)
    tokens.each_with_index.any? do |token, index|
      next false unless RAILS_ENTRYPOINTS.include?(File.basename(token.to_s))

      task_args(tokens.drop(index + 1)).any? { |arg| test_task?(arg) }
    end
  end

  # `sh -c "bin/rails test:system"`, `ssh host 'bin/rails test'`, `nix-shell --run
  # "…"` — the inner command survives shell-splitting as ONE token with spaces in it.
  # A quoted command is still a command: ask the same question of it.
  def self.quoted_inner_command_runs_suite?(tokens, root, depth)
    tokens.any? { |token| token.include?(" ") && runs_ruby_suite?(token, root, depth + 1) }
  end

  # `make test`, `./bin/ci-system`, `scripts/ci.sh` — an indirection INTO THIS REPO is
  # READABLE, so READ IT rather than assume it is inert. (An indirection we cannot read
  # is the named residue; it degrades to the foreign-runner polarity, never to a claim.)
  def self.indirection_runs_suite?(tokens, root, depth)
    return false if root.nil?

    exe, args = entrypoint(tokens)
    return false if exe.nil?
    # rails/rake are judged STRUCTURALLY above; never re-enter them as scripts.
    return false if RAILS_ENTRYPOINTS.include?(exe)
    return make_target_runs_suite?(args, root, depth) if exe == "make"

    body = repo_script_body(root, raw_entrypoint(tokens))
    return false if body.nil?

    runs_ruby_suite?(body, root, depth + 1)
  end

  # The recipe of `make <target>`, from the repo's own Makefile.
  def self.make_target_runs_suite?(args, root, depth)
    body = MAKEFILES.filter_map { |name| repo_script_body(root, name) }.first
    return false if body.nil?

    task_args(args).any? { |target| runs_ruby_suite?(make_recipe(body, target), root, depth + 1) }
  end

  # A make target's recipe: the TAB-indented lines under `<target>:`, minus make's
  # per-line `@`/`-` prefixes.
  def self.make_recipe(body, target)
    lines = body.lines
    start = lines.index { |line| line.match?(/\A#{Regexp.escape(target)}\s*:/) }
    return "" if start.nil?

    lines.drop(start + 1)
         .take_while { |line| line.start_with?("\t") }
         .map { |line| line.sub(/\A\t[@-]*/, "") }
         .join
  end

  # The body of a file INSIDE this repo, or nil when the token names no such readable
  # file (an executable on PATH, an absolute path, a binary, something enormous).
  def self.repo_script_body(root, token)
    path = repo_file(root, token)
    return nil if path.nil?
    return nil if File.size(path) > SCRIPT_SIZE_CAP

    body = File.read(path)
    return nil unless body.valid_encoding? && !body.include?("\0") # a binary is not readable

    body
  rescue StandardError
    nil
  end

  # Resolve a command token to a file in THIS repo — and only in this repo (no
  # absolute paths, no `..` escapes).
  def self.repo_file(root, token)
    token = token.to_s
    return nil if token.empty? || token.start_with?("-", "/")

    base = File.expand_path(root.to_s)
    path = File.expand_path(token.sub(%r{\A\./}, ""), base)
    return nil unless path.start_with?("#{base}#{File::SEPARATOR}")

    File.file?(path) ? path : nil
  end

  # --- the structural property (SELECTION side) ------------------------------------

  # Is this token a rails/rake task (or path) that RUNS TESTS?
  #
  # `test` — the rails test command / rake test task
  # `test:system`, `test:all`, … — its subtasks (any `test:` task but the hook)
  # `test/models/user_test.rb`, `test/integration` — a path INTO the suite
  #
  # Note what is NOT here: no list of setup tasks. `db:test:prepare` fails because
  # it is a `db:` task, not because it was enumerated. So setup tasks fail by SHAPE:
  # `assets:precompile` is an `assets:` task, `tailwindcss:build` a `tailwindcss:`
  # task — none of them IS the test task, and no setup task invented tomorrow can
  # sneak through by being one nobody listed.
  def self.test_task?(token)
    token = token.to_s
    return false if token == PREPARE_HOOK

    token == "test" || token.start_with?("test:", "test/")
  end

  # The LEADING run of non-flag arguments — the task list. Stopping at the first flag
  # is what makes `-e test` a RAILS_ENV value rather than a task.
  def self.task_args(args)
    args.take_while { |arg| !arg.to_s.start_with?("-") }
  end

  # The DIRECT probe: is this command, at position 0, a rails/rake test invocation?
  # This is the SELECTION half — what the lane can actually shell in the repo root.
  # It is deliberately NOT the net probe: see `runs_ruby_suite?`.
  def self.runs_tests?(command)
    invocations(command).any? { |tokens| direct_rails_test?(tokens) }
  end

  def self.direct_rails_test?(tokens)
    exe, args = entrypoint(tokens)
    return false unless exe && RAILS_ENTRYPOINTS.include?(exe)

    task_args(args).any? { |arg| test_task?(arg) }
  end

  # Can this lane RUN this step VERBATIM as its one command? ONE line, and a DIRECT
  # rails/rake invocation it can shell in the repo root.
  #
  # A step the lane can SEE but cannot RUN is a REFUSAL, not a fallback. That is the
  # whole reason this is a separate question from `runs_ruby_suite?`: `docker compose
  # run web bin/rails db:test:prepare test test:system` IS CI's suite (the net probe
  # says so, loudly), and this lane still cannot honestly run it — so it refuses and
  # names FULL_SUITE_TEST_CMD, instead of quietly resolving to something narrower.
  def self.runnable_here?(command)
    single_line?(command) && runs_tests?(command)
  end

  # Every command invocation in the text, as token arrays. A `run: |` block is a
  # LIST of commands (split on newlines), and each line may chain several more
  # (split on the shell separators). A `#` comment ends an invocation — otherwise a
  # commented-out line in a setup script would read as a test run.
  def self.invocations(command)
    command.to_s.lines
           .flat_map { |line| split_on_separators(safe_split(line)) }
           .map { |tokens| strip_comment(tokens) }
           .reject(&:empty?)
  end

  def self.strip_comment(tokens)
    stop = tokens.index { |token| token.start_with?("#") }
    stop ? tokens.take(stop) : tokens
  end

  # An invocation's [executable BASENAME, arguments], after stripping the noise that
  # hides the real executable: leading `FOO=bar` env assignments and a `bundle exec`
  # prefix. Shared by the direct probe and the foreign-runner sniff so both see the
  # same executable — `bundle exec rspec` is rspec, `RAILS_ENV=test bin/rails` is rails.
  def self.entrypoint(tokens)
    tokens = command_head(tokens)
    exe = tokens.first
    return [nil, []] unless exe

    [File.basename(exe), tokens.drop(1)]
  end

  # The executable token AS WRITTEN (`./bin/ci-system`, not `ci-system`) — what a
  # repo-file lookup needs.
  def self.raw_entrypoint(tokens)
    command_head(tokens).first
  end

  def self.command_head(tokens)
    tokens = tokens.drop_while { |token| ENV_ASSIGNMENT.match?(token) }
    tokens = tokens.drop(2) if tokens.first(2).map { |t| File.basename(t) } == %w[bundle exec]
    tokens
  end

  # The arguments this invocation hands to rails/rake, or nil when it does not
  # invoke rails/rake at all (`sudo apt-get …`, `npm test`, `yarn build`).
  def self.rails_args(tokens)
    exe, args = entrypoint(tokens)
    return nil unless exe && RAILS_ENTRYPOINTS.include?(exe)

    args
  end

  # --- the foreign runners --------------------------------------------------------

  # Test runners that are NOT rails. Recognized ONLY to ADD A REFUSAL — never to
  # SELECT, and never to widen what the lane runs.
  #
  # SAFE POLARITY, and do not invert it. The strict rule ("refuse on any run step we
  # cannot classify") is NOT implementable at step grain INSIDE a job we can see: the
  # HUB'S OWN `test` job carries a multi-line chromedriver-evict script that runs no
  # tests and never will be classifiable, so the strict rule refuses the hub on every
  # cert. So this sniff is a WHITELIST used in the loud direction only:
  #   * a runner nobody listed → invisible, i.e. exactly TODAY'S behavior (no worse);
  #   * a runner we DO know     → a refusal (louder).
  # Used to SELECT, the same whitelist would fail OPEN — the one runner nobody listed
  # becomes a silent green, which is the bug this module exists to kill.
  #
  # Note the grain, because it is what distinguishes this from KNOWN_INERT_ACTIONS: an
  # unlisted RUNNER sits in a job whose every step we can already read, and refusing on
  # it would brick the hub; an unlisted ACTION is a step whose contents we cannot read
  # AT ALL. Unreadable refuses; unrecognized-but-readable does not.
  #
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

    leading = task_args(args)

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

  # --- reading the workflows -------------------------------------------------------

  # EVERY job of EVERY PR-gating workflow, as
  #   { workflow:, job:, runs: [<run: text>], opaque: [<why we cannot see in>] }
  #
  # nil — and ONLY nil — when the repo has no ci.yml: there is no CI command to stand
  # in for, the lane runs the DEFAULT superset, and there is nothing to guard (see
  # WHAT THIS LANE DOES NOT CLAIM). Every other repo gets the full net check.
  #
  # OPACITY IS NOT SAFETY. The old reader SKIPPED any job with no `steps:` array and
  # called that "not raising" — but skipping is not "not raising", it is PASSING: a
  # job-level `uses:` (a reusable workflow) running the system tier resolved GREEN,
  # unread and unnamed. A job we cannot see into is NOT a job we have proven runs no
  # tests, so it is recorded as OPAQUE here and REFUSED in `refusal`.
  def self.scan(root)
    return nil unless File.file?(File.join(root.to_s, WORKFLOW))

    workflow_files(root).flat_map { |path| scan_workflow(root, path) }
  end

  def self.workflow_files(root)
    dir = File.join(root.to_s, WORKFLOW_DIR)
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, "*.{yml,yaml}")).sort
  end

  def self.scan_workflow(root, path)
    doc = YAML.safe_load_file(path, aliases: true)
    return [] unless doc.is_a?(Hash) && pr_gating?(doc)

    jobs = doc["jobs"]
    return [] unless jobs.is_a?(Hash)

    name = File.basename(path)
    jobs.map { |job, body| scan_job(name, job.to_s, body) }
  rescue StandardError
    [] # an unreadable/odd workflow must fall back, never raise inside a cert
  end

  # Does this workflow gate a PR — i.e. is its verdict part of what this lane stands in
  # for?
  #
  # MIND THE YAML: Psych parses the bare key `on:` as the BOOLEAN true (YAML 1.1), so
  # `doc["on"]` is nil for every GitHub workflow ever written. Read BOTH keys, or the
  # scan silently sees zero PR-gating workflows and this whole guard evaporates — a
  # fail-open one typo wide.
  #
  # AND FAIL CLOSED ON THE UNREADABLE. A trigger we cannot read is not proof the
  # workflow does not gate PRs, so an absent/unrecognizable `on:` is SCANNED. Only a
  # trigger block we can READ, and that carries no PR trigger, is skipped —
  # turf-monster's devnet-nightly.yml (`schedule` + `workflow_dispatch`) is the live
  # example, and the only workflow in the ecosystem this excludes.
  def self.pr_gating?(doc)
    triggers = doc.key?("on") ? doc["on"] : doc[true]

    case triggers
    when String then PR_TRIGGERS.include?(triggers)
    when Array then triggers.any? { |trigger| PR_TRIGGERS.include?(trigger.to_s) }
    when Hash then triggers.keys.any? { |trigger| PR_TRIGGERS.include?(trigger.to_s) }
    else true
    end
  end

  def self.scan_job(workflow, job, body)
    unit = { workflow: workflow, job: job, runs: [], opaque: [] }
    steps = body.is_a?(Hash) ? body["steps"] : nil

    unless steps.is_a?(Array)
      unit[:opaque] << opaque_job_reason(body)
      return unit
    end

    steps.each { |step| scan_step(step, unit) }
    unit
  end

  # A job with no `steps:` — a job-level `uses:` (a reusable/called workflow, whose
  # steps live in ANOTHER FILE and may be another repo's), or a body we cannot read.
  def self.opaque_job_reason(body)
    uses = body.is_a?(Hash) ? body["uses"] : nil
    return "job-level `uses: #{uses}` — its steps live in another workflow" if uses

    "a job body with no readable `steps:`"
  end

  def self.scan_step(step, unit)
    return unless step.is_a?(Hash)

    run = step["run"].to_s
    unless run.strip.empty?
      unit[:runs] << run
      unit[:opaque].concat(interpolated_commands(run))
      return
    end

    uses = step["uses"].to_s
    return if uses.empty?
    return if KNOWN_INERT_ACTIONS.include?(uses.split("@").first.to_s)

    unit[:opaque] << "step `uses: #{uses}` — an action this cert cannot read"
  end

  # A `run:` step whose TEXT DOES NOT SAY WHAT IT RUNS. The suite probes read a
  # command; when the command itself is interpolated, there is no command to read:
  #
  #     run: ${{ matrix.cmd }}                      # matrix TEMPLATES the whole command
  #     run: bin/rails db:test:prepare ${{ matrix.tier }}   # the TASK LIST is templated
  #     run: $SUITE                                 # the command comes from a job env var
  #     run: $(cat ci/suite-cmd.txt)                # …or from a file, at run time
  #
  # Every one of those resolved GREEN against the wrapper/opacity fixes — the parser
  # dutifully read `${{ matrix.cmd }}`, found no rails token in it, and called the job
  # inert. A templated command is NOT a command proven to run no tests: it is a command
  # we cannot see, exactly like a job with no steps. REFUSE.
  #
  # WHERE we look is load-bearing, and the hub's own CI is the calibration. We check the
  # EXECUTABLE position (any expansion at all) and the LEADING, pre-flag ARGUMENT run
  # (where a wrapper's inner command sits: `docker compose run web $SUITE`) — and a
  # WHOLE-TOKEN variable only. `sudo rm -f "$bin"` and `echo "… $(which chromedriver)"`
  # — the hub's real chromedriver-evict script, which must NEVER brick the hub's cert —
  # interpolate INSIDE an argument of a command we can already see, and stay silent.
  def self.interpolated_commands(run)
    invocations(run).filter_map do |tokens|
      why = interpolation_reason(tokens)
      next nil if why.nil?

      "step `#{label(run)}` — #{why}, so this cert cannot see what it runs"
    end
  end

  def self.interpolation_reason(tokens)
    exe = raw_entrypoint(tokens)
    return "its command is interpolated (`#{exe}`)" if exe && exe.start_with?("$")

    inner = task_args(command_head(tokens).drop(1)).find { |arg| bare_interpolation?(arg) }
    return "its command is interpolated (`#{inner}`)" if inner

    task = interpolated_rails_task(tokens)
    return "its rails task list is interpolated (`#{task}`)" if task

    nil
  end

  # A WHOLE token that is an expression/variable — `${{ matrix.cmd }}`, `$SUITE`,
  # `${SUITE}`. Deliberately NOT a partial like `$(which` (the hub's `for bin in $(which
  # -a chromedriver …)` splits into exactly that) — an unclosed substitution inside a
  # loop header is not a command position.
  def self.bare_interpolation?(token)
    token.match?(/\A\$\{\{/) || token.match?(/\A\$\{?\w+\}?\z/)
  end

  # `bin/rails db:test:prepare ${{ matrix.tier }}` — the executable is visible, the TASK
  # is not, and the task is what decides whether this runs the suite.
  def self.interpolated_rails_task(tokens)
    tokens.each_with_index do |token, index|
      next unless RAILS_ENTRYPOINTS.include?(File.basename(token.to_s))

      task = task_args(tokens.drop(index + 1)).find { |arg| bare_interpolation?(arg) }
      return task if task
    end

    nil
  end

  # The `run:` strings of the ci.yml `test` job, or nil when there is no such job to
  # read. nil means "no information"; [] means "a test job that runs no commands".
  def self.run_steps(root)
    unit = (scan(root) || []).find { |u| u[:workflow] == File.basename(WORKFLOW) && u[:job] == TEST_JOB }
    unit && unit[:runs]
  end

  # Every place CI runs the RUBY SUITE, across every PR-gating workflow and every job,
  # as [workflow, job, run] — so a refusal can NAME each one.
  #
  # This is the whole net, and the invariant is stated on it: the cert's net may not be
  # SMALLER than CI's Ruby suite, WHEREVER that suite runs. More than one entry means
  # the suite is SPLIT and a one-command lane can only ever run PART of it.
  #
  # WHY THIS DOES NOT REFUSE turf-monster TODAY — the live constraint, and the reason
  # the probes had to be structural before this scan could exist. turf's playwright job
  # is a second TEST-BEARING job right now, and it must keep resolving:
  #   * `npm test -- --shard=1/3`                              → not rails (a foreign
  #     runner in ANOTHER job is a tier this lane never claimed — see docs/topics/
  #     testing.md — not a split of the Ruby suite);
  #   * `bin/rails runner -e test e2e/seed.rb`                 → `test` is the VALUE
  #     of `-e` (the RAILS_ENV), not a task;
  #   * `bin/rails db:test:prepare` / `bin/rails tailwindcss:build` → setup, by SHAPE;
  #   * `npx playwright install --with-deps chromium`          → the INSTALL subcommand.
  # A guard that bricks a working lane is worse than the latent bug it closes — so the
  # sensitivity lives in what we can PROVE (a rails invocation, a readable indirection,
  # the system-tier markers), never in a substring sniff for the word "test".
  def self.suite_steps(root)
    (scan(root) || []).flat_map do |unit|
      unit[:runs]
        .select { |run| runs_ruby_suite?(run, root) }
        .map { |run| [unit[:workflow], unit[:job], run.strip] }
    end
  end

  # Every job/step this parser cannot see into, as [where, why].
  def self.opaque_units(root)
    (scan(root) || []).flat_map do |unit|
      unit[:opaque].map { |why| ["#{unit[:workflow]} `#{unit[:job]}`", why] }
    end
  end

  # The Ruby suite running ANYWHERE but the job this lane stands in for — [where, run].
  # Kept as its own reader because it is the shape that had been resolving in TOTAL
  # SILENCE: the reader looked at exactly `jobs.test.steps` and nowhere else.
  def self.stray_test_steps(root)
    suite_steps(root)
      .reject { |workflow, job, _run| workflow == File.basename(WORKFLOW) && job == TEST_JOB }
      .map { |workflow, job, run| [suite_label(workflow, job), run] }
  end

  def self.suite_label(workflow, job)
    workflow == File.basename(WORKFLOW) ? job : "#{workflow} `#{job}`"
  end

  # EVERY step of CI's `test` job that RUNS THE SUITE — the selection SET, not the
  # first hit, and NOT pre-filtered to the ones this lane happens to be able to run.
  # nil = no job to read; [] = a test job we recognize no suite in; ONE entry = the
  # only shape this lane can stand in for; MORE THAN ONE = CI runs its suite across
  # several commands, and a one-command lane can only ever run PART of it.
  #
  # Steps the lane CANNOT RUN are counted HERE and rejected in `for_root`,
  # deliberately: a multi-line script (or a dockerized invocation) is a test step this
  # lane cannot run, and pretending it isn't one would let a single-line step next to
  # it resolve while the script is silently dropped — the drop being the whole bug.
  # Count the suite first; judge runnability second.
  def self.test_steps(root)
    steps = run_steps(root)
    return nil unless steps.is_a?(Array)

    steps.map(&:strip).select { |run| runs_ruby_suite?(run, root) }
  end

  # Steps of the `test` job that run tests with a KNOWN FOREIGN runner and that this
  # lane would therefore DROP — `npx playwright test` or `bundle exec rspec` sitting
  # beside the rails step.
  #
  # THE COUNT'S BLIND SPOT. The set count is derived from a whitelist — and a whitelist
  # fails OPEN when COUNTING. Selection fails closed correctly (an unrecognized spelling
  # refuses, never gets picked), but the COUNT silently drops what it does not
  # recognize: `bin/rails db:test:prepare test test:system` + `npx playwright test`
  # counts ONE test step, resolves the rails one, and stamps GREEN with playwright never
  # run.
  #
  # Steps that ALREADY run the Ruby suite are excluded deliberately: chained into ONE
  # step (`bin/rails test test:system && npx playwright test`) the lane runs the whole
  # string VERBATIM, so nothing is dropped. The refusal is about steps the lane would
  # DROP — not about how many runners appear.
  def self.foreign_test_steps(root)
    steps = run_steps(root)
    return [] unless steps.is_a?(Array)

    steps.map(&:strip).select { |run| foreign_test_runner?(run) && !runs_ruby_suite?(run, root) }
  end

  # The ONE command the cert lane may run as CI's Ruby suite, or nil when there is
  # none it can honestly stand in for.
  #
  # THE INVARIANT, IN ONE PLACE. CI's Ruby suite must run in EXACTLY ONE step, of ONE
  # line, in the ONE job this lane stands in for; nothing this lane would DROP may sit
  # beside it; and NOTHING in the PR-gating workflows may be opaque to this parser.
  # Every other shape is a suite the lane could only run PART of — or could not even
  # SEE — and `refusal` turns each into a loud abort.
  def self.for_root(root)
    return nil if scan(root).nil?                  # no ci.yml → DEFAULT superset
    return nil unless opaque_units(root).empty?    # something we cannot see into

    suite = suite_steps(root)
    return nil unless suite.length == 1

    workflow, job, run = suite.first
    return nil unless workflow == File.basename(WORKFLOW) && job == TEST_JOB
    return nil unless runnable_here?(run)          # one line, a direct rails invocation
    return nil unless foreign_test_steps(root).empty?

    run
  end

  # What the cert lane should run for this repo: CI's command, else the default.
  def self.resolve(root)
    for_root(root) || DEFAULT
  end

  # The LOUD half. Returns an operator-facing message when this repo has CI we can read
  # but CANNOT honestly stand in for — and nil when the cert may proceed. The caller
  # aborts on it (bin/full-suite-check), because a cert that cannot find CI's suite must
  # refuse, not quietly certify something else.
  #
  # Deliberately silent for a repo with NO ci.yml: DEFAULT is a full-suite superset
  # there, which is honest — it just isn't CI's own line.
  def self.refusal(root)
    return nil if scan(root).nil?
    return nil if for_root(root)

    opaque = opaque_units(root)
    suite = suite_steps(root)
    steps = run_steps(root)

    return opaque_refusal(root, opaque) if opaque.any?
    return split_refusal(root, suite) if suite.length > 1
    return unrunnable_refusal(root, suite.first) if suite.length == 1 && unrunnable_reason(suite.first)
    return foreign_refusal(root) if foreign_test_steps(root).any?
    return no_tests_refusal(root, steps) if steps.is_a?(Array) && steps.any?

    nil # a ci.yml with no `test` job and no Ruby suite anywhere: DEFAULT is a superset
  end

  # We can SEE CI's whole suite, in ONE step — and this lane still may not run it. Why
  # not, or nil when the single suite step is one this lane could run (in which case the
  # refusal is about something else sitting BESIDE it — see `foreign_refusal`).
  def self.unrunnable_reason(entry)
    workflow, job, run = entry

    return :multiline unless single_line?(run)
    return :wrapper unless runs_tests?(run)
    return :outside_test_job unless workflow == File.basename(WORKFLOW) && job == TEST_JOB

    nil
  end

  # We cannot SEE part of CI. That is not the same as having proven it runs no tests.
  def self.opaque_refusal(root, opaque)
    seen = opaque.map { |where, why| "#{where}: #{why}" }
    "#{workflow_path(root)}'s CI has #{opaque.length} unit(s) this cert CANNOT SEE INTO " \
      "(#{seen.inspect}). A job whose steps this parser cannot read is NOT a job proven to run no tests — and a " \
      "Ruby suite hiding in one certifies GREEN with a whole tier NEVER RUN, which is precisely the lie this lane " \
      "exists to kill. Prove it inert (inline the steps, or add the action to CiTestCommand::KNOWN_INERT_ACTIONS " \
      "in bin/lib/ci_test_command.rb once you have checked it runs no tests), or set FULL_SUITE_TEST_CMD to the " \
      "single command that runs this repo's whole Ruby suite."
  end

  # The suite is SPLIT. One lane, one command — it can only ever run PART of it.
  def self.split_refusal(root, suite)
    seen = suite.map { |workflow, job, run| "#{suite_label(workflow, job)}: #{label(run)}" }
    same_job = suite.map { |workflow, job, _run| [workflow, job] }.uniq.length == 1
    grain = same_job ? "in #{suite.length} STEPS of its `#{TEST_JOB}` job" : "in MORE THAN ONE JOB"

    "#{workflow_path(root)} runs its Ruby test suite #{grain} (#{seen.inspect}). This cert lane runs ONE command, " \
      "so it would certify on one of them and leave the rest NEVER RUN — a green cert with a whole tier missing. " \
      "Collapse CI's Ruby suite into one command, or set FULL_SUITE_TEST_CMD to the single command that runs all " \
      "of it."
  end

  # We can SEE CI's whole suite, in ONE step — and this lane cannot run it verbatim, or
  # it does not live in the job this lane stands in for. Refuse; never narrow to
  # something else.
  def self.unrunnable_refusal(root, entry)
    workflow, job, run = entry
    where = suite_label(workflow, job)

    case unrunnable_reason(entry)
    when :multiline
      "#{workflow_path(root)} runs its Ruby suite from a MULTI-LINE `run:` script (#{where}: #{label(run)}), and " \
        "this cert lane runs ONE command — it will not run a mangled first line and call it CI's suite. Set " \
        "FULL_SUITE_TEST_CMD to the single command that runs CI's suite for this repo, or collapse the CI step to " \
        "one line."
    when :wrapper
      "#{workflow_path(root)} runs its Ruby suite through a command this lane cannot invoke VERBATIM (#{where}: " \
        "`#{label(run)}`) — the executable is not rails/rake, so the suite runs inside a WRAPPER (a container, a " \
        "shell, a script) this cert cannot reproduce. It will not fall back to a NARROWER command and call that " \
        "CI's suite. Set FULL_SUITE_TEST_CMD to the single command that runs this repo's whole Ruby suite."
    else
      "#{workflow_path(root)} runs its Ruby suite in `#{where}`, NOT the `#{TEST_JOB}` job this cert lane stands " \
        "in for (#{label(run)}). This lane resolves its command from the `#{TEST_JOB}` job, so it would certify " \
        "having NEVER RUN that suite. Move the suite into the `#{TEST_JOB}` job, or set FULL_SUITE_TEST_CMD to the " \
        "command that runs it."
    end
  end

  def self.foreign_refusal(root)
    foreign = foreign_test_steps(root)
    rails = (test_steps(root) || []).first
    beside = rails ? "certifying on `#{label(rails)}` alone" : "certifying without it"

    "#{workflow_path(root)}'s `#{TEST_JOB}` job runs tests with ANOTHER RUNNER beside its rails step " \
      "(#{foreign.map { |run| label(run) }.inspect}), and this cert lane runs ONE command — #{beside} silently " \
      "DROPS it, which is how a green cert lands with a whole tier NEVER RUN. Set FULL_SUITE_TEST_CMD to the " \
      "single command that runs both, chain them into one step, or move the other runner into its own job (this " \
      "lane stands in for CI's Ruby suite, not its every tier — see docs/topics/testing.md)."
  end

  def self.no_tests_refusal(root, steps)
    "#{workflow_path(root)}'s `#{TEST_JOB}` job has #{steps.length} `run` step(s) and NONE of them runs tests " \
      "(#{steps.map { |run| label(run) }.inspect}). This cert stands in for CI, so it will not certify a command " \
      "that runs no tests — that is how a green cert comes to mean nothing. Add the test step to CI, or set " \
      "FULL_SUITE_TEST_CMD to the command that runs this repo's suite."
  end

  def self.workflow_path(root)
    File.join(root.to_s, WORKFLOW)
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
  # STRUCTURAL and EXACT, like the rest of the SELECTION side: the `test:system` TASK,
  # or a path into test/system. `bin/rails test test/system` runs the tier too, and a
  # substring probe for "test:system" misses that form entirely.
  #
  # This is the "what tier does this command run?" answer, and it is deliberately not
  # the whole BROWSER GUARD. Being structural at position 0, it sees no WRAPPER form
  # (`docker compose run web bin/rails test:system` — the executable is docker), and a
  # guard that must fail SAFE cannot afford that miss. bin/lib/system_test_browser.rb
  # therefore UNIONS this with a textual probe; the asymmetry that forces the union is
  # argued there. Keep this half exact — the safety belongs with the guard, not here.
  def self.system_tier?(cmd)
    invocations(cmd).any? do |tokens|
      args = rails_args(tokens)
      next false if args.nil?

      task_args(args).any? { |arg| arg == "test:system" || arg == "test/system" || arg.start_with?("test/system/") }
    end
  end

  def self.single_line?(command)
    command.to_s.strip.lines.length == 1
  end
end
