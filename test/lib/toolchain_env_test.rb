# frozen_string_literal: true

# [unit] tests for bin/lib/toolchain_env.rb — the pre-toolchain environment
# restore that bin/clean-artifacts hands each audited app.
#
# Every case here feeds a SYNTHETIC parent hash rather than reading ENV, because
# the property under test is "what does this do with a parent of shape X" and the
# real ENV is whichever shape the runner happens to have. The end-to-end proof
# that a restored child reaches the same verdict as a clean one — both arms of
# the ablation — lives in test/lib/clean_artifacts_cli_test.rb, which spawns the
# real CLI against real processes.
# Run directly:
#   ruby -Itest test/lib/toolchain_env_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/toolchain_env"

class ToolchainEnvTest < Minitest::Test
  ORIG = ToolchainEnv::BUNDLER_PREFIX
  NIL_SENTINEL = ToolchainEnv::BUNDLER_ABSENT
  MISE = ToolchainEnv::MISE_ORIG_PATH

  def restored(env) = ToolchainEnv.restored(env)

  # ── THE CONSTANTS ARE BUNDLER'S, NOT OURS ──────────────────────────────────
  #
  # This module reimplements `Bundler.original_env` instead of requiring bundler,
  # because it runs in a process that must not be bound to any bundle. The cost
  # of that choice is two spellings typed by hand — and the first draft got the
  # sentinel wrong, writing "BUNDLER_ENV_PRESERVED". Nothing raised: every
  # preserved variable was SET TO THE SENTENCE instead of deleted, `ruby` died on
  # the resulting RUBYOPT before any app boot began, and four fixture apps went
  # from OK to unbootable. A guessed protocol constant fails silently in exactly
  # the direction this module exists to prevent, so it is pinned to the source.
  def test_the_sentinel_and_prefix_match_bundlers_own
    require "bundler"
    require "bundler/environment_preserver"

    assert_equal Bundler::EnvironmentPreserver::INTENTIONALLY_NIL, NIL_SENTINEL,
                 "bundler's absent-variable sentinel moved. A stale spelling here does not raise — it " \
                 "SETS every preserved variable to the sentinel string instead of deleting it."
    assert_equal Bundler::EnvironmentPreserver::BUNDLER_PREFIX, ORIG,
                 "bundler's record prefix moved, so nothing this module restores would be found"
  end

  # ── THE MISE LANE: THE BUG THIS MODULE SHIPPED FOR ─────────────────────────

  def test_the_mise_record_restores_path_and_is_consumed
    child = restored({ "PATH" => "/mise/ruby/bin:/usr/bin", MISE => "/usr/bin" })

    assert_equal "/usr/bin", child["PATH"],
                 "mise's own record of the PATH it replaced was not honoured — this is the archive " \
                 "lane's failure verbatim: every audited app booted under the release runner's Ruby"
    refute child.key?(MISE), "the record is consumed; a pre-mise shell did not carry it"
  end

  def test_an_empty_mise_record_is_not_a_restore_target
    child = restored({ "PATH" => "/mise/ruby/bin:/usr/bin", MISE => "" })

    assert_equal "/mise/ruby/bin:/usr/bin", child["PATH"],
                 "an empty record is absence, not an instruction to blank the child's PATH"
  end

  # ── THE BUNDLER LANE ───────────────────────────────────────────────────────

  def test_a_preserved_variable_is_restored_to_its_pre_bundler_value
    child = restored({ "PATH" => "/bundle/bin:/usr/bin", "#{ORIG}PATH" => "/usr/bin" })

    assert_equal "/usr/bin", child["PATH"]
    refute child.key?("#{ORIG}PATH"), "the record itself must not follow the child"
  end

  # THE REGRESSION THAT COST FOUR FIXTURES. The sentinel means "this was UNSET
  # before bundler ran", so the restore is a DELETE. Setting it literally hands
  # the child `RUBYOPT=BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL`, and ruby
  # refuses to start.
  def test_the_absent_sentinel_deletes_the_variable_rather_than_setting_it
    child = restored({ "RUBYOPT" => "-rbundler/setup", "#{ORIG}RUBYOPT" => NIL_SENTINEL })

    refute child.key?("RUBYOPT"),
           "the sentinel was written through as a VALUE. A child with RUBYOPT set to bundler's " \
           "sentinel string cannot start ruby at all."
    refute_equal NIL_SENTINEL, child["RUBYOPT"]
  end

  # ── THE PROPERTY THE SIX-NAME LIST DID NOT HAVE ────────────────────────────
  #
  # This is the whole argument for the rewrite. The old scrub could only cover
  # variables somebody had already thought of, which is why PATH — the one that
  # mattered — was missing from it for the life of the script. A record NAMES ITS
  # OWN VARIABLE, so a variable this file has never heard of is restored anyway.
  # If this test ever needs a new constant added to the module to pass, the
  # enumeration has grown back.
  def test_a_variable_this_module_never_names_is_still_restored
    invented = "SOME_TOOLCHAIN_VAR_NOBODY_ENUMERATED"
    refute_includes File.read(File.expand_path("../../bin/lib/toolchain_env.rb", __dir__)), invented,
                    "this test only proves the wholesale property while the module does NOT name the variable"

    child = restored({ invented => "contaminated", "#{ORIG}#{invented}" => "original" })

    assert_equal "original", child[invented],
                 "a preserved variable outside this module's vocabulary was left contaminated — the " \
                 "restore has degenerated back into an enumeration"
  end

  # ── NOT A REGRESSION ON WHAT THE OLD SCRUB CAUGHT ──────────────────────────
  #
  # The replacement must be a SUPERSET. These are the exact six names the removed
  # child_env hash zeroed; none may survive into the child on a parent that
  # carries no record for them.
  REPLACED_SCRUB = %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG RUBYOPT RUBYLIB BUNDLER_VERSION].freeze

  def test_every_name_the_old_scrub_zeroed_is_still_neutralised
    parent = REPLACED_SCRUB.to_h { |key| [key, "contaminated"] }

    child = restored(parent)

    survivors = REPLACED_SCRUB.select { |key| child.key?(key) }
    assert_empty survivors,
                 "these were zeroed by the six-name scrub this module replaced and now reach the " \
                 "audited app's boot: #{survivors.join(', ')}"
  end

  # The namespace rule, not a longer list: a BUNDLE_ variable nobody enumerated
  # is cleared because of its NAMESPACE, which is where bundler keeps all config.
  def test_an_unenumerated_bundle_variable_is_cleared_by_its_namespace
    child = restored({ "BUNDLE_SOMETHING_NEW" => "contaminated" })

    refute child.key?("BUNDLE_SOMETHING_NEW")
  end

  # ...but the records must survive the namespace sweep to be readable, and
  # BUNDLER_ is not BUNDLE_. A regex one character looser eats its own input.
  def test_the_namespace_sweep_does_not_eat_the_records_it_reads
    child = restored({ "PATH" => "/bundle/bin", "#{ORIG}PATH" => "/usr/bin" })

    assert_equal "/usr/bin", child["PATH"],
                 "the BUNDLE_ namespace sweep consumed BUNDLER_ORIG_PATH before it could be read"
  end

  # ...and the case the test above CANNOT reach. It probes with PATH, which is
  # outside both namespaces, and step 1 reads the records out of the SOURCE hash
  # before the sweep runs — so PATH is restored either way and that assertion
  # passes on a widened regex as readily as on the real one. Measured in review
  # 2026-09-22: widening BUNDLE_NAMESPACE by ONE character (/\ABUNDLE/, or
  # /\ABUNDLER?_/) left all 14 cases green while silently dropping this restore.
  # BUNDLER_VERSION is the probe because it is load-bearing TWICE — a real
  # Bundler::EnvironmentPreserver::BUNDLER_KEYS member that a widened regex
  # clears after step 1 restored it, AND a RESIDUAL_KEYS name, so it also reds
  # if step 3's `unless overrides.key?` floor guard is dropped. Both guards are
  # asserted here; neither had a test that could fail.
  def test_a_bundler_prefixed_target_survives_the_sweep_and_the_floor
    child = restored({ "BUNDLER_VERSION" => "2.6.9", "#{ORIG}BUNDLER_VERSION" => "2.5.23" })

    assert_equal "2.5.23", child["BUNDLER_VERSION"],
                 "a restored BUNDLER_ value was lost. Either the BUNDLE_ namespace sweep widened to " \
                 "reach BUNDLER_, or step 3's residual floor clobbered a restore step 1 had made."
  end

  # ── LAYERING ───────────────────────────────────────────────────────────────

  # `mise activate` runs in the login shell, outside any `bundle exec`, so its
  # record is the deeper of the two: bundler's "original" PATH is already
  # mise-modified.
  def test_mise_wins_path_when_both_records_are_present
    child = restored({
                       "PATH" => "/mise/ruby/bin:/mise/node/bin:/usr/bin",
                       "#{ORIG}PATH" => "/mise/node/bin:/usr/bin",
                       MISE => "/usr/bin"
                     })

    assert_equal "/usr/bin", child["PATH"],
                 "bundler's record won, so the child kept a PATH that mise had already rewritten"
  end

  def test_a_clean_parent_keeps_its_path
    child = restored({ "PATH" => "/usr/bin", "HOME" => "/home/alex" })

    assert_equal "/usr/bin", child["PATH"], "nothing recorded a change, so there is nothing to undo"
    assert_equal "/home/alex", child["HOME"], "unrelated variables are not this module's business"
  end

  def test_overrides_are_spawn_shaped
    overrides = ToolchainEnv.child_overrides({ "RUBYOPT" => "-rbundler/setup", MISE => "/usr/bin" })

    overrides.each_value do |value|
      assert value.nil? || value.is_a?(String),
             "Process.spawn accepts only a String or nil per key; got #{value.class}"
    end
  end

  # ── THE INTERPRETER THE CHILD WILL ACTUALLY RUN ────────────────────────────

  def test_resolved_ruby_reads_the_restored_path_not_the_live_one
    decoy = File.dirname(RbConfig.ruby)
    parent = { "PATH" => "/nonexistent-decoy-bin", MISE => decoy }

    assert_equal File.join(decoy, "ruby"), ToolchainEnv.resolved_ruby(parent),
                 "the reported interpreter must be the one the CHILD gets, or the audit's most " \
                 "diagnostic line describes a process nobody ran"
  end

  def test_resolved_ruby_is_nil_rather_than_a_guess_when_no_ruby_is_on_the_path
    assert_nil ToolchainEnv.resolved_ruby({ "PATH" => "/nonexistent-decoy-bin" })
  end
end
