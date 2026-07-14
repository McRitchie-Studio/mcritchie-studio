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

  # --- the JOB-grain split -------------------------------------------------------
  #
  # The resolver read exactly `jobs.test.steps`, so the SAME suite split that refuses
  # across STEPS resolved QUIETLY across JOBS: the cert took the narrower command,
  # dropped the system tier, and stamped green. Third spelling of the lying cert.
  #
  # THE POSITIVE INVARIANT these pin: the cert's net may not be SMALLER than CI's
  # RUBY SUITE, wherever in the workflow that suite runs — not just in one job.

  def test_a_suite_split_across_JOBS_refuses
    # THE BUG. Ordinary CI refactor: move the system tier into its own job for
    # parallelism. `jobs.test` still holds one single-line rails test step, so every
    # STEP-grain guard passes — and the cert certifies `bin/rails test` with the
    # system tier NEVER RUN, in a different job, entirely unread.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Install packages
              run: sudo apt-get update && sudo apt-get install -y postgresql-client
            - name: Run tests
              run: bin/rails db:test:prepare test
        system_test:
          steps:
            - name: Run system tests
              run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir),
                 "resolved to the `test` job's narrower command and dropped CI's other test JOB"

      refusal = CiTestCommand.refusal(dir).to_s
      assert_match(/MORE THAN ONE JOB/, refusal)
      assert_match(/system_test/, refusal, "the refusal must NAME the job it saw")
      assert_match(/test:system/, refusal, "and the step it saw")
    end
  end

  def test_a_second_test_job_is_seen_under_ANY_name
    # By CONTENT, not by name — the resolver may not be blinded by what the second
    # job is called, exactly as it may not be blinded by what a STEP is called.
    %w[e2e ruby-system zzz_extra].each do |job|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails test
          #{job}:
            steps:
              - run: bundle exec rails test:system
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir), "a test job named `#{job}` went unseen"
        assert_match(/#{Regexp.escape(job)}/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  def test_a_stray_test_step_in_a_NON_test_job_refuses
    # A vector nobody proposed: nobody adds a `system_test` job — they append a rails
    # test step to a job that already exists (here, `lint`). Same hole, no new job.
    # Also pins the ENV-ASSIGNMENT prefix path across the job boundary.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test
        lint:
          steps:
            - run: bin/rubocop -f github
            - run: RAILS_ENV=test bin/rails test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/lint/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_the_test_job_running_NO_tests_while_another_job_does_refuses
    # The migrated suite: `jobs.test` is left holding only setup. Today's message
    # ("NONE of them runs tests") is true but points at the wrong place — the tests
    # DO exist, one job over, and the refusal must say so.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare
        ruby-tests:
          steps:
            - run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/ruby-tests/, CiTestCommand.refusal(dir).to_s)
    end
  end

  # --- the JOB-grain split: what must NOT refuse ---------------------------------
  #
  # The cross-job scan is only safe because `runs_tests?` is STRUCTURAL. These are
  # the live vectors it has to clear: a substring sniff would refuse turf-monster's
  # cert lane TODAY, and a guard that bricks a working lane is worse than the latent
  # bug it closes.

  def test_a_turf_style_PLAYWRIGHT_job_beside_the_test_job_still_resolves
    # turf-monster's REAL second test-bearing job, reproduced. It runs a different
    # TIER with a different runner (npm/playwright), plus rails SETUP invocations
    # that must not read as tests: `bin/rails runner -e test e2e/seed.rb` (that
    # `test` is the VALUE of -e, the RAILS_ENV) and `bin/rails tailwindcss:build`.
    #
    # This lane stands in for CI's RUBY suite; playwright is a tier it never claimed
    # (see docs/topics/testing.md). Refuse here and turf-monster's cert lane — which
    # works today — starts aborting on every run.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
        playwright:
          strategy:
            matrix:
              shard: [1, 2, 3]
          steps:
            - name: Seed test DB
              run: bin/rails db:test:prepare && bin/rails runner -e test e2e/seed.rb
            - name: Build Tailwind CSS for the test server
              run: bin/rails tailwindcss:build
            - name: Run Playwright (excluding @devnet)
              run: npm test -- --grep-invert "@devnet" --shard=1/3
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir),
                   "turf-monster's playwright job must not brick its cert lane"
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  def test_rails_SETUP_steps_in_other_jobs_do_not_refuse
    # `db:migrate`, `assets:precompile`, `db:seed` are rails invocations in other
    # jobs that run no tests. They fail by SHAPE (not one of them IS the test task),
    # so no enumeration of setup tasks is needed here either.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system
        deploy:
          steps:
            - run: bin/rails db:migrate
            - run: bin/rails db:seed
        assets:
          steps:
            - run: bin/rails assets:precompile
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  # --- THE OPAQUE: a job this cert CANNOT SEE INTO -------------------------------
  #
  # THE TEST THAT ASSERTED THE WRONG PROPERTY. This used to be
  # `test_a_job_with_no_steps_does_not_crash_the_scan`, and it asserted that a
  # `uses:` job RESOLVES GREEN — pinning the bug as if it were the feature. "Must not
  # RAISE" is not "must not LIE": a cert that does not crash while certifying nothing
  # is the exact failure this module exists to kill, and a test proving it doesn't
  # crash proves nothing about that.
  #
  # A job with no readable `steps:` is not a job we have PROVEN runs no tests. It is a
  # job we cannot see. REFUSE, and NAME it.

  def test_a_job_this_cert_CANNOT_SEE_INTO_refuses
    # A job-level `uses:` (a reusable/called workflow) has NO steps: its steps live in
    # another file. Read `jobs.test.steps` and this job is INVISIBLE — so the system
    # tier can move here and the cert stamps GREEN having never run it.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          uses: ./.github/workflows/system.yml
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir),
                 "a job whose steps this cert cannot read must never resolve GREEN"
      refusal = CiTestCommand.refusal(dir).to_s
      assert_match(/CANNOT SEE INTO/, refusal)
      assert_match(/system_test/, refusal, "the refusal must NAME the job it could not read")
      assert_match(%r{\./\.github/workflows/system\.yml}, refusal, "…and its `uses:` target")
    end
  end

  def test_an_UNREADABLE_job_body_refuses_rather_than_being_skipped
    # A null job body is legal YAML and has no steps either. Same rule, same reason:
    # skipping is not "not raising" — it is PASSING.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system
        empty:
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/CANNOT SEE INTO/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_a_composite_ACTION_step_refuses_because_its_steps_live_elsewhere
    # `uses: ./.github/actions/x` — the steps are in another file, so a suite can hide
    # in one exactly like a job-level `uses:`.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - uses: ./.github/actions/run-system-tests
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/run-system-tests/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_the_actions_the_ECOSYSTEM_really_uses_are_proven_inert_and_do_not_refuse
    # THE OVER-FIRE GUARD RAIL for the opacity rule. Every `uses:` in the four live
    # ci.yml files must be on KNOWN_INERT_ACTIONS, or this rule bricks every repo in
    # the ecosystem on its next cert. If a repo adds a new action, this is where the
    # cost lands: a human decides "does it run tests?" ONCE — that is the point.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - uses: actions/checkout@v7
            - uses: ruby/setup-ruby@v1
            - uses: browser-actions/setup-chrome@v1
            - uses: actions/setup-node@v4
            - uses: actions/cache@v4
            - run: bin/rails db:test:prepare test test:system
            - uses: actions/upload-artifact@v4
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.refusal(dir),
                 "the actions the live ci.yml files really use must be PROVEN INERT, not opaque"
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
    end
  end

  def test_a_version_BUMP_of_an_inert_action_does_not_refuse
    # KNOWN_INERT_ACTIONS matches owner/repo, not owner/repo@ref — so a Dependabot bump
    # cannot brick a cert lane.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - uses: actions/checkout@v99
            - run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) { |dir| assert_nil CiTestCommand.refusal(dir) }
  end

  def test_the_HUBS_OWN_workflow_has_no_stray_test_job
    # The live pin. The cross-job scan runs against the hub's REAL ci.yml on every
    # cert: its scan_ruby (brakeman), scan_js (importmap audit) and lint (rubocop)
    # jobs must read as ZERO test steps. If this goes red, the hub's own cert lane
    # is refusing — which is how we learn the scan over-fires, HERE, not at a gate.
    assert_nil CiTestCommand.refusal(HUB_ROOT),
               "the cross-job scan must not refuse the hub's own ci.yml"
    assert_equal CiTestCommand::DEFAULT, CiTestCommand.for_root(HUB_ROOT)
  end

  # --- a FOREIGN test runner beside the rails step -------------------------------
  #
  # The set COUNT is derived from the `runs_tests?` whitelist, and a whitelist fails
  # OPEN when COUNTING: selection correctly refuses an unrecognized spelling, but the
  # count silently DROPS it — so a non-rails test step beside the rails one certified
  # green with that step never run. #538's round-2 defect, in the parser's blind spot.
  #
  # SAFE POLARITY: the known-runner sniff may only ADD A REFUSAL, never SELECT.

  def test_a_foreign_test_runner_beside_the_rails_step_refuses
    ["npx playwright test", "npm test", "bundle exec rspec", "make test", "yarn test:e2e",
     "pnpm run test:ci", "go test ./...", "npx jest", "pytest -q"].each do |runner|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - name: Run tests
                run: bin/rails db:test:prepare test test:system
              - name: Run the other tests
                run: #{runner}
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir),
                   "`#{runner}` was silently DROPPED and the rails step certified green"
        assert_match(/ANOTHER RUNNER/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  def test_the_foreign_runner_refusal_names_what_it_saw
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system
            - run: npx playwright test --grep-invert "@devnet"
    YAML
    with_ci(yaml) do |dir|
      assert_match(/playwright/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_a_foreign_runner_CHAINED_INSIDE_the_rails_step_still_resolves
    # The boundary, and the reason the sniff excludes steps that already run rails
    # tests: chained into ONE step, the lane runs the whole string VERBATIM — the
    # playwright run HAPPENS. The refusal is about steps the lane would DROP, not
    # about how many runners appear.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system && npx playwright test
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system && npx playwright test",
                   CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  def test_a_SHIMMED_foreign_runner_beside_the_rails_step_refuses
    # The shims. `npx playwright test` is an invocation OF playwright, and so are
    # `pnpm dlx playwright test` and `npm exec jest` — the sniff must see THROUGH the
    # shim, or the same drop hides behind one extra word.
    ["npx playwright test", "pnpm dlx playwright test", "npm exec jest",
     "yarn dlx vitest run"].each do |runner|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails db:test:prepare test test:system
              - run: #{runner}
      YAML
      with_ci(yaml) { |dir| assert_nil CiTestCommand.for_root(dir), "`#{runner}` was DROPPED" }
    end
  end

  def test_NON_test_uses_of_the_known_runners_do_not_refuse
    # The over-fire check, and the sharpest vector here: `npx playwright install
    # --with-deps chromium` is what turf-monster's CI really runs one step ABOVE its
    # real playwright call. Sniff the EXECUTABLE alone and this reads as a test run —
    # so the guard refuses a repo for INSTALLING A BROWSER. (This vector caught exactly
    # that bug in the first cut of the sniff.) `npm ci`, `npm run build`, `yarn
    # install`, `go build`, `make setup` are the same shape.
    ["npm ci", "npm install", "npm run build", "yarn install --frozen-lockfile",
     "go build ./...", "make setup", "npx playwright install --with-deps chromium",
     "pnpm dlx playwright install"].each do |setup|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: #{setup}
              - run: bin/rails db:test:prepare test test:system
      YAML
      with_ci(yaml) do |dir|
        assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir),
                     "`#{setup}` is SETUP and must not refuse"
        assert_nil CiTestCommand.refusal(dir)
      end
    end
  end

  def test_an_UNCLASSIFIABLE_step_degrades_to_todays_behavior
    # THE POLARITY, asserted. An opaque script we cannot classify is NOT a refusal:
    # the hub's own `test` job carries a multi-line chromedriver-evict script, so
    # "refuse on anything unrecognized" would refuse the HUB. A missed runner
    # degrades to today's silence; a KNOWN one adds loudness. Do not invert this.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Evict any chromedriver on PATH
              run: |
                for bin in $(which -a chromedriver 2>/dev/null); do sudo rm -f "$bin"; done
                echo "chromedriver remaining: $(which chromedriver 2>/dev/null || echo none)"
            - name: Some house script
              run: ./bin/ci-extra.sh
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  # --- THE NET, AT WORKFLOW GRAIN -------------------------------------------------
  #
  # Everything below is ONE bug in nine spellings: THE PARSER LOOKED AT A NARROWER
  # SLICE OF CI THAN CI ACTUALLY RUNS, so the Ruby suite could sit somewhere it never
  # looked and the cert stamped GREEN with a tier NEVER RUN.
  #
  # Each of these vectors was VERIFIED GREEN against the previous round's code before
  # the fix landed. They are not hypotheticals — they are the transcript of a guard
  # being walked past nine different ways. So do not test them one spelling at a time:
  # the ASSERTION is the property — "CI's Ruby suite runs where this cert can SEE it
  # and RUN it, or the cert REFUSES" — and these are merely the vectors that prove the
  # property holds where it used to leak.

  # A step's command is a command WHEREVER the rails invocation sits in it. Enumerating
  # wrappers would miss the next one; there is no end to that list.
  def test_a_WRAPPED_rails_suite_in_another_job_refuses
    ["docker compose run web bin/rails db:test:prepare test:system",
     "ssh runner bin/rails db:test:prepare test:system",
     "timeout 30m bin/rails db:test:prepare test:system",
     "sudo -u ci bin/rails db:test:prepare test:system",
     "nix-shell --run bin/rails db:test:prepare test:system",
     "docker compose run web bin/rails test test/system"].each do |wrapped|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails test
          system_test:
            steps:
              - run: #{wrapped}
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir),
                   "`#{wrapped}` is CI's system tier, one job over — it must never resolve to the narrow half"
        assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  # THE VECTOR THAT ACTUALLY TESTS THE STRUCTURAL FIX — and the one the first cut of
  # these tests MISSED. Every wrapper vector above carries a literal `test:system` /
  # `test/system`, so the TEXTUAL half of the probe catches them all: neuter the
  # wrapper-transparent structural probe entirely and those tests still pass. They
  # prove the union, not the parser.
  #
  # A wrapped UNIT tier carries NO marker at all. Only "a rails invocation ANYWHERE in
  # the line" can see it — so THIS is what fails if anyone narrows the probe back to
  # position 0. (Mutation-proved: it does.)
  def test_a_WRAPPED_suite_with_NO_TEXTUAL_MARKER_still_refuses
    ["docker compose run web bin/rails test",
     "docker compose run --rm web bundle exec rails test",
     "timeout 30m bin/rails test test/models",
     "sudo -u ci bin/rake test",
     "ssh runner bin/rails test"].each do |wrapped|
      refute wrapped.include?("test:system"), "vector must be invisible to the textual probe"
      refute wrapped.include?("test/system"), "vector must be invisible to the textual probe"
      refute CiTestCommand.runs_tests?(wrapped), "…and invisible to the OLD position-0 probe"
      assert CiTestCommand.runs_ruby_suite?(wrapped), "the NET probe must still SEE `#{wrapped}`"

      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails test test/models
          unit_extra:
            steps:
              - run: #{wrapped}
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir), "`#{wrapped}` is CI's suite, one job over, in a wrapper"
        assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  # The same wrapper, in the TEST job itself: the lane can SEE the suite and cannot RUN
  # it. That is a REFUSAL, never a quiet fallback to a narrower command.
  def test_a_WRAPPED_suite_in_the_test_job_refuses_rather_than_narrowing
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: docker compose run web bin/rails db:test:prepare test test:system
    YAML
    with_ci(yaml) do |dir|
      cmd = "docker compose run web bin/rails db:test:prepare test test:system"
      assert CiTestCommand.runs_ruby_suite?(cmd), "the NET probe must SEE a wrapped suite"
      refute CiTestCommand.runnable_here?(cmd), "the SELECTION probe must refuse to run it verbatim"
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/WRAPPER/, CiTestCommand.refusal(dir).to_s)
    end
  end

  # THE TEXTUAL HALF OF THE NET PROBE, and the vector that PROVES it earns its keep.
  #
  # Everything the structural probe can see, it sees better. The textual markers are
  # load-bearing in exactly one place: an indirection this cert CANNOT read, handed the
  # tier as an argument — `./bin/ci-runner test:system`, a house script that is not in
  # the repo (or not readable). No rails token, nothing to follow — and the command
  # still says, in plain text, that it runs the system tier.
  #
  # Drop the textual union and NOTHING else in this file goes red (mutation-proved —
  # that is why this test exists). That is precisely how the browser guard lost its
  # textual half in the shared-probe refactor: untested code is code the next
  # simplification deletes.
  def test_an_UNREADABLE_indirection_that_NAMES_the_tier_refuses
    ["./bin/ci-runner test:system",
     "ci/run-suite test/system",
     "some-global-tool run test:system"].each do |named|
      refute CiTestCommand.runs_tests?(named), "no rails token: the structural probe cannot see this"
      assert CiTestCommand.runs_ruby_suite?(named), "the TEXTUAL half must: the command NAMES the tier"

      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails test
          system_test:
            steps:
              - run: #{named}
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir)
        assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  def test_a_QUOTED_inner_command_is_still_a_command
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - run: sh -c "bin/rails db:test:prepare test:system"
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
    end
  end

  # A `container:` job needs NO new code — its steps' `run:` text is unchanged, and the
  # property reads the text. Pinned so a future "simplification" cannot regress it.
  def test_a_CONTAINER_job_running_the_suite_refuses
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          container: ruby:3.3
          steps:
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) { |dir| assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s) }
  end

  def test_a_MATRIX_job_whose_steps_come_from_a_yaml_anchor_refuses
    # YAML aliases are resolved by the parser (`aliases: true`), so templated steps
    # materialize and the property sees them.
    yaml = <<~YAML
      x-suite: &suite
        - run: bin/rails db:test:prepare test:system
      jobs:
        test:
          steps:
            - run: bin/rails test
        tiers:
          strategy:
            matrix:
              tier: [system]
          steps: *suite
    YAML
    with_ci(yaml) { |dir| assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s) }
  end

  # An indirection INTO THIS REPO is READABLE. Read it, rather than assume it is inert.
  def test_a_MAKEFILE_target_that_runs_the_suite_refuses
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - run: make system
    YAML
    with_ci(yaml) do |dir|
      File.write(File.join(dir, "Makefile"), "system:\n\tbin/rails db:test:prepare test:system\n")
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
    end
  end

  def test_a_REPO_LOCAL_SCRIPT_that_runs_the_suite_refuses
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - run: ./bin/ci-system
    YAML
    with_ci(yaml) do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "ci-system"), "#!/bin/sh\nbin/rails db:test:prepare test:system\n")
      assert_nil CiTestCommand.for_root(dir)
      assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s)
    end
  end

  # A repo-local script that runs NO tests must stay SILENT — the same read, the other
  # verdict. This is the over-fire guard for following indirections at all: the hub's
  # own `bin/brakeman`, `bin/importmap` and `bin/rubocop` are exactly this shape.
  def test_a_repo_local_script_that_runs_NO_tests_does_not_refuse
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system
        scan:
          steps:
            - run: ./bin/scan
    YAML
    with_ci(yaml) do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "scan"), "#!/bin/sh\nbin/brakeman --no-pager\n")
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
      assert_nil CiTestCommand.refusal(dir)
    end
  end

  # --- THE INTERPOLATED COMMAND ---------------------------------------------------
  #
  # A command whose TEXT does not say what it runs is not a command proven to run no
  # tests. All four of these resolved GREEN against the wrapper + opacity fixes: the
  # parser read `${{ matrix.cmd }}`, found no rails token, and called the job inert.

  def test_an_INTERPOLATED_command_refuses
    ["${{ matrix.cmd }}",                          # the matrix templates the command
     "bin/rails db:test:prepare ${{ matrix.tier }}", # …or just the TASK LIST
     "$SUITE",                                     # the command comes from a job env var
     "$(cat ci/suite-cmd.txt)",                    # …or from a file, at run time
     "docker compose run web $SUITE"].each do |templated|
      yaml = <<~YAML
        jobs:
          test:
            steps:
              - run: bin/rails test
          tiers:
            steps:
              - run: #{templated.include?('${{') ? "\"#{templated}\"" : templated}
      YAML
      with_ci(yaml) do |dir|
        assert_nil CiTestCommand.for_root(dir),
                   "`#{templated}` could BE the system tier — the cert cannot see what it runs"
        assert_match(/CANNOT SEE INTO/, CiTestCommand.refusal(dir).to_s)
      end
    end
  end

  # THE OVER-FIRE GUARD for the interpolation rule, and it is the HUB'S OWN CI. Its
  # chromedriver-evict script interpolates INSIDE the arguments of commands we can
  # already see (`sudo rm -f "$bin"`, `echo "… $(which chromedriver)"`), and turf's
  # playwright job templates a SHARD, not a command (`npm test -- --shard=${{ … }}`).
  # Refuse on those and every repo in the ecosystem is bricked.
  def test_interpolation_INSIDE_a_visible_command_does_not_refuse
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - name: Evict any chromedriver on PATH
              run: |
                for bin in $(which -a chromedriver 2>/dev/null); do sudo rm -f "$bin"; done
                sudo rm -f /usr/local/bin/chromedriver || true
                echo "chromedriver remaining on PATH: $(which chromedriver 2>/dev/null || echo none)"
            - run: bin/rails db:test:prepare test test:system
        playwright:
          steps:
            - run: npm test -- --grep-invert "@devnet" --shard=${{ matrix.shard }}/${{ strategy.job-total }}
            - run: bin/rails runner -e test e2e/seed.rb
    YAML
    with_ci(yaml) do |dir|
      assert_nil CiTestCommand.refusal(dir),
                 "the HUB's own chromedriver script and turf's sharded playwright job must NEVER brick a cert"
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
    end
  end

  # --- THE WORKFLOW FILE ITSELF ---------------------------------------------------

  def test_the_suite_in_a_SIBLING_pr_gating_workflow_refuses
    # The net is not `jobs.test.steps` of ci.yml. It is CI's Ruby suite, wherever in the
    # PR verdict it runs — including another workflow FILE.
    yaml = <<~YAML
      on: [pull_request]
      jobs:
        test:
          steps:
            - run: bin/rails test
    YAML
    sibling = <<~YAML
      on: [pull_request]
      jobs:
        system:
          steps:
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      File.write(File.join(dir, ".github", "workflows", "system.yml"), sibling)
      assert_nil CiTestCommand.for_root(dir)
      refusal = CiTestCommand.refusal(dir).to_s
      assert_match(/MORE THAN ONE JOB/, refusal)
      assert_match(/system\.yml/, refusal, "the refusal must NAME the workflow file it found the suite in")
    end
  end

  def test_a_NON_pr_gating_workflow_is_NOT_part_of_the_net
    # THE OVER-FIRE GUARD for reading sibling workflows, and it is turf-monster's REAL
    # devnet-nightly.yml: a SCHEDULED workflow is not part of the verdict this lane
    # stands in for. Read it into the net and turf's cert lane refuses on every run.
    yaml = <<~YAML
      on: [pull_request]
      jobs:
        test:
          steps:
            - run: bin/rails db:test:prepare test test:system
    YAML
    nightly = <<~YAML
      on:
        schedule:
          - cron: "0 7 * * *"
        workflow_dispatch:
      jobs:
        devnet:
          steps:
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) do |dir|
      File.write(File.join(dir, ".github", "workflows", "devnet-nightly.yml"), nightly)
      assert_nil CiTestCommand.refusal(dir),
                 "a scheduled (non-PR) workflow is not part of the PR verdict this lane stands in for"
      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(dir)
    end
  end

  def test_psych_parses_the_bare_on_key_as_TRUE_and_the_scan_survives_it
    # MIND THE YAML: Psych reads the bare key `on:` as the BOOLEAN true (YAML 1.1), so
    # `doc["on"]` is nil for every GitHub workflow ever written. Read only "on" and the
    # scan sees ZERO pr-gating workflows and this entire guard evaporates — a fail-open
    # one typo wide. This asserts the guard still FIRES through the real spelling.
    assert_equal({ true => "pull_request" }, YAML.safe_load("on: pull_request"),
                 "if Psych ever stops folding `on:` into true, simplify pr_gating? — until then, do NOT")

    yaml = <<~YAML
      on:
        pull_request:
        push:
          branches: [ main ]
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) { |dir| assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s) }
  end

  def test_an_unreadable_trigger_is_scanned_rather_than_skipped
    # Fail closed: a trigger we cannot read is not proof the workflow does not gate PRs.
    yaml = <<~YAML
      jobs:
        test:
          steps:
            - run: bin/rails test
        system_test:
          steps:
            - run: bin/rails db:test:prepare test:system
    YAML
    with_ci(yaml) { |dir| assert_match(/MORE THAN ONE JOB/, CiTestCommand.refusal(dir).to_s) }
  end

  # --- THE LIVE ECOSYSTEM: the over-fire guard rail, on the real files -------------

  def test_EVERY_ecosystem_repo_still_resolves_CLEAN
    # The guard that matters most. A cert lane that REFUSES a working repo is worse
    # than the latent bug it closes, so every repo in the ecosystem is run through the
    # REAL parser against its REAL workflows on every suite run. Siblings are skipped
    # when absent (CI checks out only this repo), so this is a LOCAL pin — which is
    # exactly where an over-fire would otherwise be discovered: at a builder's gate.
    %w[mcritchie-studio turf-monster rolio chain-ops studio-engine solana-studio turf-vault].each do |repo|
      root = File.expand_path("../../../#{repo}", HUB_ROOT)
      next unless File.directory?(root)

      assert_nil CiTestCommand.refusal(root),
                 "the cert net REFUSES #{repo} — the guard over-fires on a live repo"
      assert_includes CiTestCommand.resolve(root), "test:system",
                      "#{repo}'s cert lane must still carry the system tier"
    end
  end

  def test_the_four_RAILS_repos_resolve_their_OWN_ci_command
    # …and they resolve it from their own ci.yml — not by falling back to DEFAULT with
    # a refusal quietly suppressed.
    %w[mcritchie-studio turf-monster rolio chain-ops].each do |repo|
      root = File.expand_path("../../../#{repo}", HUB_ROOT)
      next unless File.directory?(root)

      assert_equal "bin/rails db:test:prepare test test:system", CiTestCommand.for_root(root),
                   "#{repo} must RESOLVE its own ci.yml test command, not fall back"
    end
  end
end
