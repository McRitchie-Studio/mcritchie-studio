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

  def test_returns_nil_when_the_test_job_has_no_bin_rails_step
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
    refute CiTestCommand.system_tier?("bin/rails test")
    refute CiTestCommand.system_tier?("bin/rails test test/integration")
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
