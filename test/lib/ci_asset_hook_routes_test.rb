require "test_helper"
require "shellwords"
require "yaml"

# WHO BUILDS THE CSS ON A VIRGIN CI RUNNER — asserted against ci.yml, not described.
#
# app/assets/builds/ is gitignored, so a CI runner starts with no tailwind.css and every
# view-rendering test 500s without one. `test:prepare` is what builds it (tailwindcss-rails'
# build.rake enhances the first DEFINED of test:prepare / spec:prepare / db:test:prepare, and
# railties always defines the first), and a run reaches that task by exactly TWO routes:
#
#   1. INVOKE IT — the command names `test:prepare` itself.
#   2. SPAWN INTO IT — the command names a rake TEST TASK (`test`, `test:system`, …) and the
#      `rails <task>` that task's body spawns carries no path and no `-n`, so
#      Rails::Command::TestCommand's `run_prepare_task if
#      self.args.none?(EXACT_TEST_ARGUMENT_PATTERN)` fires. A path argument, a `-n` filter, or
#      TEST=/TESTOPTS= on the line silences it while the command still READS the same.
#
# WHY THIS FILE EXISTS. Three comments in this repo credited CI with running an ARGLESS
# `bin/rails test`, and CI has never run one: its Rails lane shards through bin/ci-shard
# (route 1) and its system job is rake-routed (route 2). The words were retired by
# retire-argless-rails-test-claim; prose alone would rot again the next time the invocation
# changes, so the claim is pinned HERE instead. Change ci.yml to a path-arg run with no
# prepare and this reddens, naming the step — a virgin-runner CSS failure caught at the
# cause rather than as dozens of unexplained asset errors.
#
# The companion guard is test/lib/tasks/test_prepare_asset_hook_test.rb, which pins the
# rake/railties/tailwindcss links this file's ROUTES depend on. This one pins which routes
# CI's own steps take.
#
# Run directly:
#   bin/rails test test/lib/ci_asset_hook_routes_test.rb
class CiAssetHookRoutesTest < ActiveSupport::TestCase
  CI_YML = Rails.root.join(".github", "workflows", "ci.yml")

  # Compared by BASENAME so a path can't hide them (`bin/rails`, `./bin/rake`, `rails`).
  RAILS_ENTRYPOINTS = %w[rails rake].freeze

  # Rake/rails tasks that RUN the minitest suite. `test:prepare` is deliberately absent —
  # it prepares, it does not run tests.
  TEST_TASKS = %w[test test:all test:system test:units test:functionals test:integration
                  test:models test:controllers test:jobs test:mailers].freeze

  PREPARE_TASK = "test:prepare"

  # The same pattern Rails uses to decide whether an argument "looks like a test to run",
  # which is what suppresses the prepare task (railties' Runner::PATH_ARGUMENT_PATTERN plus
  # TestCommand's -n/--name half). Copied rather than required so this guard still runs if
  # the constant moves; the copy is exercised against the real command strings below.
  FILTER_ARGUMENT = %r{\A-n|\A--name\b|\A(?!/.+/\z)[.\w]*[/\\]}

  # An env assignment that reaches the spawned argv and silences the hook: rake's `test`
  # task passes ENV["TEST"] positionally and run_from_rake splices ENV["TESTOPTS"].
  SILENCING_ENV = /\A(TEST|TESTOPTS)=/

  # `test:prepare` inside a SCRIPT body, and the two ways that scan lies if written the
  # obvious way. The lookbehind rejects `db:test:prepare`, which CONTAINS the token and
  # does NOT build the CSS (tailwindcss enhances db:test:prepare only where test:prepare is
  # undefined, which in a Rails app it never is); comment lines are dropped by `code_lines`,
  # because bin/ci-shard's own header EXPLAINS the hook at length. Measured while writing
  # this file: with a plain /\btest:prepare\b/ over the whole body, deleting the real
  # invocation from bin/ci-shard left this guard GREEN — the prose alone satisfied it.
  PREPARE_INVOCATION = /(?<![:\w-])test:prepare\b/

  test "[unit] the route classifier reads real command shapes, including the silent ones" do
    assert_equal :invokes_prepare, route_for("bin/rails db:test:prepare test:prepare")
    assert_equal :invokes_prepare, route_for("bin/rails db:test:prepare test:prepare && bin/rails test test/a_test.rb")
    assert_equal :spawns_argless, route_for("bin/rails db:test:prepare test:system")
    assert_equal :spawns_argless, route_for("bin/rails db:test:prepare test test:system")
    assert_equal :spawns_argless, route_for("bin/rails test")

    assert_nil route_for("bin/rails test test/models/task_test.rb"),
               "a path argument suppresses the prepare task, so a path-arg step reaches the " \
               "hook by NEITHER route and must not be classified as covered."
    assert_nil route_for("bin/rails test -n /some_test/")
    assert_nil route_for("TEST=test/models/task_test.rb bin/rails db:test:prepare test"),
               "TEST= lands in the spawned argv, so the line silences the hook while still " \
               "reading like the covered one."
    assert_nil route_for("bin/rails db:test:prepare"), "db:test:prepare is not the hook"
    assert_nil route_for("bundle exec rubocop")
  end

  # The script half of the classifier, driven directly — the half that read a COMMENT as an
  # invocation until this test existed.
  test "[unit] a script counts only when its CODE invokes the hook, not when it explains it" do
    invoking = %(# runs test:prepare for the shard\nunless system(env, "bin/rails", "db:test:prepare", "test:prepare")\n)
    explaining = %(# Rails' test:prepare hook is what compiles the CSS.\nsystem(env, "bin/rails", "db:test:prepare")\n)
    db_only = %(system(env, "bin/rails", "db:test:prepare")\n)

    assert script_invokes_prepare?(invoking)
    refute script_invokes_prepare?(explaining),
           "a comment ABOUT test:prepare is not an invocation of it — that read is how this " \
           "guard first passed on a bin/ci-shard with the real call deleted."
    refute script_invokes_prepare?(db_only),
           "db:test:prepare CONTAINS the token and does not build the CSS; the classifier " \
           "must not count it."

    assert script_runs_suite?(%(system(env, "bin/rails", "test", *shard_files)\n))
    refute script_runs_suite?(%(# every invocation below passes paths to bin/rails test\nputs "hi"\n))
  end

  test "[unit] no CI step runs an argless rails test, the claim three comments used to make" do
    argless = suite_lines.select { |line| rails_args(line) == ["test"] }

    assert_empty argless,
                 "A CI step now runs an argless `bin/rails test`: #{argless.inspect}. That is " \
                 "not a failure — it is a comment update. bin/fast-check, bin/agent-worktree, " \
                 "test/lib/fast_check_test.rb, test/lib/feature_shape_tiers_test.rb and " \
                 "test/lib/tasks/test_prepare_asset_hook_test.rb all state that no CI " \
                 "invocation is argless (retire-argless-rails-test-claim). Fix them together."
  end

  test "[integration] every CI step that runs the Ruby suite reaches test:prepare" do
    lines = suite_lines

    assert_operator lines.size, :>=, 2,
                    "Found #{lines.size} suite-running step(s) in #{CI_YML}. This guard asserts " \
                    "over that set, so an empty or near-empty one means the reader broke, not " \
                    "that CI got simpler — every assertion below would pass vacuously."

    uncovered = lines.reject { |line| route_for(line) }

    assert_empty uncovered,
                 "These CI steps run the Ruby suite and reach `test:prepare` by NEITHER route " \
                 "— they neither invoke it nor spawn an unfiltered `rails <task>`: " \
                 "#{uncovered.inspect}. On a virgin runner app/assets/builds/tailwind.css is " \
                 "never built and every view-rendering test errors with `The asset " \
                 "\"tailwind.css\" is not present in the asset pipeline`. Add " \
                 "`bin/rails db:test:prepare test:prepare` to the step, as bin/ci-shard does."
  end

  test "[integration] CI takes BOTH routes, so neither half of the mechanism is untested here" do
    routes = suite_lines.filter_map { |line| route_for(line) }.uniq.sort

    assert_equal %i[invokes_prepare spawns_argless].sort, routes,
                 "CI's steps now take these routes to test:prepare: #{routes.inspect}. Both were " \
                 "live when this guard was written (the sharded `rails` lane invokes the task " \
                 "inside bin/ci-shard; the `system` job spawns into it), and the comments that " \
                 "describe the mechanism name both. If a route genuinely went away, retire it " \
                 "from those comments in the same change."
  end

  private
    # Every `run:` line in ci.yml that runs the minitest suite — directly, or through a
    # repo-local script whose body does. A multi-line `run:` block is split, because each
    # line is its own command.
    def suite_lines
      run_steps.flat_map { |step| step.to_s.lines }.map(&:strip).reject(&:empty?)
               .select { |line| suite_line?(line) }
    end

    def run_steps
      jobs = YAML.safe_load_file(CI_YML, aliases: true).fetch("jobs", {})
      jobs.values.grep(Hash).flat_map { |job| Array(job["steps"]).grep(Hash).map { |s| s["run"] } }.compact
    end

    def suite_line?(line)
      return true if rails_args(line).any? { |arg| TEST_TASKS.include?(arg) }

      script_runs_suite?(local_script_body(line))
    end

    # Does this script's CODE run the suite / invoke the hook? Coarse on purpose — matching
    # the body cannot go stale against a refactor the way a hardcoded lane list would — but
    # never coarse enough to be satisfied by a comment ABOUT the hook.
    def script_runs_suite?(body)
      code_lines(body).any? { |line| line.match?(/\b(rails|rake)\b[^\n]*\btest\b/) }
    end

    def script_invokes_prepare?(body)
      code_lines(body).any? { |line| line.match?(/\b(rails|rake)\b/) && line.match?(PREPARE_INVOCATION) }
    end

    def code_lines(body)
      body.to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    end

    # :invokes_prepare — the step (or the repo-local script it calls) names test:prepare.
    # :spawns_argless — it names a rake TEST TASK and nothing on the line filters the spawn.
    # nil — neither, which on a virgin runner means no CSS.
    def route_for(line)
      return :invokes_prepare if rails_args(line).include?(PREPARE_TASK)
      return :invokes_prepare if script_invokes_prepare?(local_script_body(line))

      args = rails_args(line)
      return nil unless args.any? { |arg| TEST_TASKS.include?(arg) }
      return nil if args.any? { |arg| FILTER_ARGUMENT.match?(arg) }
      return nil if tokens(line).any? { |token| SILENCING_ENV.match?(token) }

      :spawns_argless
    end

    # The task list handed to a rails/rake entrypoint on this line, empty when there is none.
    def rails_args(line)
      parts = tokens(line)
      index = parts.index { |token| RAILS_ENTRYPOINTS.include?(File.basename(token)) }
      return [] unless index

      parts[(index + 1)..].to_a.take_while { |token| token != "&&" && token != "|" && token != ";" }
    end

    # A repo-local script the line invokes (bin/ci-shard), read from the tree. Coarse on
    # purpose — matching the script's BODY cannot go stale against a refactor the way a
    # hardcoded lane list would, and a false PASS needs the text to literally be there.
    def local_script_body(line)
      first = tokens(line).first.to_s
      return nil unless first.start_with?("bin/", "./bin/")

      path = Rails.root.join(first.delete_prefix("./"))
      path.file? ? path.read : nil
    end

    def tokens(line)
      Shellwords.split(line)
    rescue ArgumentError
      line.split
    end
end
