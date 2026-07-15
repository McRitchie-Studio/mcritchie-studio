# frozen_string_literal: true

# [unit] tests for bin/lib/ci_test_command.rb — "what does CI actually run?",
# resolved from the repo's OWN .github/workflows/ci.yml so a cert lane cannot
# silently test less than CI. Pure parsing; no processes are spawned. The
# ORCHESTRATION (which lane uses it) is covered by test/lib/full_suite_check_test.rb.
# Run directly:
#   ruby -Itest test/lib/ci_test_command_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../bin/lib/ci_test_command"

class CiTestCommandTest < Minitest::Test
  HUB_ROOT = File.expand_path("../..", __dir__)

  def with_ci(yaml)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
      File.write(File.join(dir, ".github", "workflows", "ci.yml"), yaml) if yaml
      yield dir
    end
  end

  # --- parsing -----------------------------------------------------------------

  def test_reads_the_bin_rails_step_of_the_ci_test_job
    # Located by CONTENT (`bin/rails`), not by step name — renaming the step must
    # not blind the resolver into silently falling back.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - uses: actions/checkout@v4
            - name: Set up Ruby
              run: bundle install
            - name: Whatever this step is called tomorrow
              run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
    end
  end

  def test_returns_nil_when_the_repo_has_no_ci_workflow
    with_ci(nil) { |dir| assert_nil CiTestCommand.for_root(dir) }
  end

  def test_returns_nil_when_the_test_job_has_no_rails_test_step
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: npm test
    YAML
    with_ci(yaml) { |dir| assert_nil CiTestCommand.for_root(dir) }
  end

  def test_ignores_a_multiline_run_block_it_cannot_invoke_verbatim
    # A `run: |` block is a SCRIPT, not a single command — the cert lane runs one
    # command string, so an unparseable shape must fall back rather than run a
    # mangled first line.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: |
                bin/rails db:test:prepare
                bin/rails test
    YAML
    with_ci(yaml) { |dir| assert_nil CiTestCommand.for_root(dir) }
  end

  # --- SELECT ON THE PROPERTY, NOT THE SPELLING --------------------------------
  # THE BUG THIS FILE WAS BOUNCED FOR. Selecting CI's command by "the first step
  # that mentions bin/rails and is one line" makes every SETUP step a candidate:
  # a `bin/rails db:test:prepare` step parked AHEAD of the real one becomes the
  # "full-suite lane", runs, exits 0, and stamps green having run ZERO tests. The
  # resolver now selects on what a step DOES — `runs_tests?`.
  #
  # These are the adversarial shapes: a setup task ahead of the tests, the tests
  # not first, and the two real-world hijackers from turf-monster's playwright job
  # (`tailwindcss:build`, and a `&&` chain whose `-e test` is an ENV VALUE, not a
  # task). Each must select the REAL test step.

  def test_a_setup_step_ahead_of_the_tests_does_not_hijack_the_selection
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Prepare the test database
              run: bin/rails db:test:prepare
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir),
                   "a SETUP step was selected as the test lane — it runs, exits 0, and certifies NOTHING"
    end
  end

  def test_setup_shapes_that_must_never_be_selected_as_the_test_lane
    ["bin/rails assets:precompile",
     "bin/rails tailwindcss:build",
     "bin/rails db:prepare",
     "bin/rails db:test:prepare",
     "bin/rails db:test:prepare && bin/rails runner -e test e2e/seed.rb"].each do |setup|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: #{setup}
              - run: bin/rails db:test:prepare test test:system
      YAML
      with_ci(yaml) do |dir|
        assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir),
                     "#{setup.inspect} runs no tests and must never be selected as the test lane"
      end
    end
  end

  def test_runs_tests_asserts_the_property_structurally
    # POSITIVE — the invocation is handed the test task, a test: subtask, or a path
    # into test/. Note the shapes nobody writes in ci.yml today but might tomorrow.
    assert CiTestCommand.runs_tests?("bin/rails test")
    assert CiTestCommand.runs_tests?("bin/rails db:test:prepare test test:system")
    assert CiTestCommand.runs_tests?("bin/rails test:system")
    assert CiTestCommand.runs_tests?("bin/rails test test/integration")
    assert CiTestCommand.runs_tests?("RAILS_ENV=test bin/rails db:test:prepare test test:system")
    assert CiTestCommand.runs_tests?("bundle exec rails test test:system")
    assert CiTestCommand.runs_tests?("bin/rake test")
    assert CiTestCommand.runs_tests?("bin/rails db:test:prepare && bin/rails test")

    # NEGATIVE — setup tasks fail by SHAPE (a `db:`/`assets:`/`tailwindcss:` task is
    # not the test task), so no setup task invented tomorrow sneaks through.
    refute CiTestCommand.runs_tests?("bin/rails db:test:prepare")
    refute CiTestCommand.runs_tests?("bin/rails db:prepare")
    refute CiTestCommand.runs_tests?("bin/rails assets:precompile")
    refute CiTestCommand.runs_tests?("bin/rails tailwindcss:build")
    refute CiTestCommand.runs_tests?("bin/rails test:prepare"), "test:prepare is the PREP HOOK — it runs no tests"
    refute CiTestCommand.runs_tests?("sudo apt-get update && sudo apt-get install -y curl")
    refute CiTestCommand.runs_tests?("npm test")
    refute CiTestCommand.runs_tests?("")

    # THE `-e test` TRAP (turf-monster's playwright seed step, verbatim): that bare
    # `test` is the VALUE of -e — the RAILS_ENV — not a task. A token scan reads it
    # as a test run; scanning only the leading NON-FLAG args does not.
    refute CiTestCommand.runs_tests?("bin/rails db:test:prepare && bin/rails runner -e test e2e/seed.rb")
  end

  # --- refusal: a cert that can't find CI's tests must SAY so -------------------
  # Fail CLOSED. `runs_tests?` is a whitelist, so an unrecognized test spelling reads
  # as "no test step" — and that must be LOUD, never a silent pass, or the parser's
  # blindness becomes a green cert.

  def test_a_test_job_whose_steps_run_no_tests_is_a_refusal
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare
            - run: bin/rails assets:precompile
    YAML
    with_ci(yaml) do |dir|
      refusal = CiTestCommand.refusal(dir)

      refute_nil refusal, "a test job that runs NO tests must refuse, not silently certify something else"
      assert_match(/NONE of them runs tests/, refusal)
      assert_match(/db:test:prepare/, refusal, "the refusal must NAME what it saw, so it is actionable")
    end
  end

  def test_a_multiline_test_script_is_a_refusal_not_a_silent_fallback
    # CI DOES run tests here — as a script the cert lane cannot invoke verbatim.
    # Falling back to DEFAULT would silently run something that is NOT CI's suite
    # while claiming CI-independence, so say it out loud instead.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: |
                bin/rails db:test:prepare
                bin/rails test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_match(/MULTI-LINE/, CiTestCommand.refusal(dir).to_s)
    end
  end

  # --- CI RUNS ITS TESTS IN MORE THAN ONE STEP ---------------------------------
  # THE SECOND BOUNCE. The multi-LINE script above already refused, for the reason
  # that "a suite this ONE-command lane can only run PART of is not a suite it can
  # certify". The multi-STEP spelling of that same failure fails OPEN: the resolver
  # `.find`-ed the FIRST test step and silently dropped the rest.
  #
  # The trigger is not exotic. It is the most ordinary CI refactor there is — split
  # the system tier into its own step so the log reads nicely:
  #
  #     - name: Run tests          run: bin/rails test
  #     - name: Run system tests   run: bin/rails db:test:prepare test:system
  #
  # The lane then certified on `bin/rails test`: GREEN, with test/system NEVER RUN.
  # That is precisely the bug this whole task exists to kill, respelled. Only the hub
  # is pinned by test_the_fallback_default_matches_the_hubs_own_ci_command; turf-monster
  # and rolio have no such guard, and full-suite-check is rolio's ONLY cert route.
  #
  # The invariant is now positive and singular: CI runs its tests in EXACTLY ONE
  # step, and that step is ONE line. Everything else refuses.

  def test_tests_split_across_two_steps_is_a_refusal_not_a_silent_first_pick
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Run tests
              run: bin/rails test
            - name: Run system tests
              run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      refusal = CiTestCommand.refusal(dir)

      assert_nil CiTestCommand.for_root(dir),
                 "picked ONE of CI's two test steps — a green cert with the system tier NEVER RUN"
      refute_nil refusal, "CI's suite is split across steps and this lane runs ONE command — it must REFUSE"
      assert_match(/2 STEPS/, refusal, "the refusal must say HOW MANY steps it saw")
      assert_match(/bin\/rails test/, refusal, "the refusal must NAME the steps, so it is actionable")
      assert_match(/test:system/, refusal, "the refusal must name the step that would have been DROPPED")
      assert_match(/FULL_SUITE_TEST_CMD/, refusal, "the refusal must hand over the way out")
    end
  end

  def test_the_dropped_step_is_exactly_the_system_tier_the_cert_would_have_missed
    # The consequence, spelled out: had the resolver picked the first step, the cert
    # would have run a command with NO system tier — the original bug, restored.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      refute CiTestCommand.system_tier?("bin/rails test"),
             "sanity: the step the OLD resolver picked carries no system tier"
      assert_nil CiTestCommand.for_root(dir), "so it must not be selectable at all"
    end
  end

  def test_three_test_steps_refuse_and_the_message_counts_them
    # Sharding the suite into tiers — unit, integration, system — is a normal thing
    # for a CI to do. It is still N commands, and this lane runs one.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Unit
              run: bin/rails test test/models
            - name: Integration
              run: bin/rails test test/integration
            - name: System
              run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/3 STEPS/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_a_single_line_test_step_beside_a_multiline_test_script_refuses
    # The mixed shape, and the reason `test_steps` counts SCRIPTS too. Filter the
    # scripts out before counting and this resolves to the single-line step while
    # CI's other test step is silently dropped — the same drop, one layer down.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
            - name: Extra tests
              run: |
                export FOO=1
                bin/rails test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir),
                 "resolved to the runnable step and dropped CI's other test step"
      assert_match(/2 STEPS/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_a_test_step_FOLLOWED_by_a_setup_step_still_resolves
    # The near-miss that must NOT refuse: only ONE step runs tests. A setup step
    # AFTER the tests is still a setup step — the count is what matters, not the
    # position, and over-refusing would break every repo with a trailing step.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
            - name: Precompile
              run: bin/rails assets:precompile
            - name: Upload coverage
              run: bin/rails coverage:report
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir), "one test step + trailing setup is CI's suite, verbatim"
    end
  end

  def test_a_matrix_test_job_with_one_test_step_still_resolves
    # A `strategy: matrix` job is still ONE list of steps. The matrix must not be
    # mistaken for a split suite — CI runs this one command, per matrix leg.
    yaml = <<~YAML
      jobs:
        test:
          strategy:
            matrix:
              ruby: ["3.3", "3.4"]
          steps:
            - name: Setup
              run: bundle install
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  def test_a_matrix_test_job_that_shards_tests_across_steps_refuses
    yaml = <<~YAML
      jobs:
        test:
          strategy:
            matrix:
              shard: [1, 2]
          steps:
            - name: Run tests
              run: bin/rails test
            - name: Run system tests
              run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/2 STEPS/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_several_test_invocations_CHAINED_INSIDE_one_step_still_resolve
    # The boundary of the rule. `&&`-chaining the tiers inside ONE step is ONE
    # command string — the lane CAN run it verbatim, so it must not refuse. The
    # refusal is about steps the lane would DROP, not about how many tiers run.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare && bin/rails test && bin/rails test:system
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare && bin/rails test && bin/rails test:system",
                   CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
      assert CiTestCommand.system_tier?(CiTestCommand.resolve(dir)), "and the browser guard still sees the tier"
    end
  end

  def test_no_ci_workflow_is_not_a_refusal
    # The one benign case: nothing to read, so DEFAULT (a full-suite SUPERSET) is
    # honest. It runs MORE than CI, never less — that can't produce a lying cert.
    with_ci(nil) { |dir| assert_nil CiTestCommand.refusal(dir) }
    with_ci("jobs: [this is not: a map\n") { |dir| assert_nil CiTestCommand.refusal(dir) }
  end

  # NOTE on the OTHER repos. turf-monster's and rolio's ci.yml cannot be asserted
  # from the hub's suite — they are not checked out in CI, and a test that skips
  # when its subject is absent asserts nothing. The hub's own ci.yml IS pinned
  # (test_the_hub_resolves_to_its_own_ci_command, and the DEFAULT drift guard
  # below), and both now also guard the multi-STEP case for free: split the hub's
  # CI into two test steps and `for_root` returns nil, so those tests go red. For
  # turf-monster and rolio the REFUSAL is the guard — it fires at cert time, in
  # their own root, which is the only place the truth is readable.

  def test_a_readable_test_command_is_not_a_refusal
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare
            - run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) { |dir| assert_nil CiTestCommand.refusal(dir) }
  end

  def test_malformed_yaml_falls_back_instead_of_raising
    with_ci("jobs: [this is not: a map\n") do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_equal CiTestCommand::DEFAULT, CiTestCommand.resolve(dir)
    end
  end

  # --- resolve -----------------------------------------------------------------

  def test_resolve_prefers_the_repos_own_ci_command
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system test/extra
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system test/extra", CiTestCommand.resolve(dir)
    end
  end

  def test_resolve_falls_back_to_a_default_that_still_runs_the_system_tier
    # THE BUG THIS CLOSES, in its fallback form: a cert that claims to stand in for
    # CI must never fall back to a command that tests LESS than CI. `bin/rails test`
    # SKIPS test/system.
    with_ci(nil) do |dir|
      assert_equal CiTestCommand::DEFAULT, CiTestCommand.resolve(dir)
      assert_includes CiTestCommand.resolve(dir), "test:system"
    end
  end

  # --- the shape trap ----------------------------------------------------------

  def test_the_default_keeps_db_test_prepare_FIRST_so_rake_runs_both_tiers
    # SHAPE TRAP — do not "simplify" this command. `test` is a real rails COMMAND,
    # so `bin/rails test test:system` parses `test:system` as a PATH and dies with
    # `LoadError: cannot load such file -- <root>/test:system`. Both tiers run only
    # because a leading NON-command (db:test:prepare) routes the line through RAKE,
    # where `test` and `test:system` are two separate tasks. (It is also what makes
    # the line self-prepare its assets: Rails skips test:prepare — the hook that
    # builds the gitignored tailwind.css — whenever an argument looks like a path.)
    argv = Shellwords.split(CiTestCommand::DEFAULT)

    assert_equal %w[bin/rails db:test:prepare test test:system], argv
    assert_equal "db:test:prepare", argv[1],
                 "a rails-COMMAND first arg would parse the later tiers as file paths"
  end

  def test_system_tier_detects_which_commands_run_test_system
    assert CiTestCommand.system_tier?("bin/rails db:test:prepare test test:system")
    assert CiTestCommand.system_tier?("bin/rails test test/system"),
           "the PATH form runs the tier too — miss it and the caller loses its browser guard"
    refute CiTestCommand.system_tier?("bin/rails test")
    refute CiTestCommand.system_tier?("bin/rails test test/integration")
    refute CiTestCommand.system_tier?("bin/rails db:test:prepare"),
           "a setup step needs no browser — it runs no tests at all"
  end

  # --- the drift guard ---------------------------------------------------------

  def test_the_fallback_default_matches_the_hubs_own_ci_command
    # THE DRIFT GUARD for the fallback. For a repo WITH a ci.yml the resolver reads
    # it, so drift is impossible by construction; the only string that can rot is
    # DEFAULT. Assert it against the hub's REAL ci.yml so changing either side alone
    # fails HERE, at the seam, with the tiers named.
    ci = CiTestCommand.for_root(HUB_ROOT)

    refute_nil ci, "the hub's ci.yml `test` job no longer has a single bin/rails step — the guard is blind"
    assert_equal ci, CiTestCommand::DEFAULT,
                 "the cert's fallback command must run CI's full suite (base + system tiers), verbatim"
  end

  def test_the_hub_resolves_to_its_own_ci_command
    assert_equal CiTestCommand.for_root(HUB_ROOT), CiTestCommand.resolve(HUB_ROOT)
    assert_includes CiTestCommand.resolve(HUB_ROOT), "test:system"
  end
end
