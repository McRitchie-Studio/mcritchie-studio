# frozen_string_literal: true

# [unit] Git's background maintenance must be disarmed for every test process.
#
#   ruby -Itest test/lib/git_isolation_plugin_test.rb
#
# NOTE THE IRONY, and it is load-bearing: run this file the way that header line
# says and the plugin under test DOES NOT LOAD (a non-bundler `ruby` resolves
# minitest 6, which dropped automatic plugin discovery). So these tests never
# assert on ambient process state — every one DRIVES a real `git` subprocess
# with an explicit env, which is the only way they can be true under both
# invocations. That is deliberate; do not "simplify" them into reading ENV.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class GitIsolationPluginTest < Minitest::Test
  PLUGIN = File.expand_path("../../test/minitest/git_isolation_plugin.rb", __dir__)

  def setup
    ENV.delete("GIT_CONFIG_SYSTEM")
    ENV.delete("GIT_ISOLATION")
    GitIsolationPlugin.instance_variable_set(:@config_path, nil) if defined?(GitIsolationPlugin)
    load PLUGIN
  end

  # THE PROPERTY THAT KILLS THE FLAKE. Not "the env var is set" — that is a
  # restatement of the code. What matters is what GIT resolves in a repo the
  # fixtures actually create.
  def test_a_throwaway_repo_resolves_maintenance_disarmed
    in_repo do |dir, env|
      assert_equal "false", git(dir, env, "config", "--get", "maintenance.auto"),
                   "git must resolve maintenance.auto=false inside a throwaway repo, or " \
                   "housekeeping can fire while Dir.mktmpdir tears the directory down"
      assert_equal "0", git(dir, env, "config", "--get", "gc.auto")
    end
  end

  # SYSTEM CONFIG IS THE LOWEST PRECEDENCE LAYER, which is exactly why it was
  # chosen: a fixture that sets its own value still wins. If this ever fails, the
  # plugin has been moved to a layer that MASKS what tests deliberately configure.
  def test_a_repo_local_setting_still_overrides_the_floor
    in_repo do |dir, env|
      git(dir, env, "config", "maintenance.auto", "true")

      assert_equal "true", git(dir, env, "config", "--get", "maintenance.auto"),
                   "a repo-local git config must outrank the system-level floor"
    end
  end

  # The opt-out has to actually opt out, or it is decoration. Named explicitly
  # (GIT_ISOLATION=off) rather than `||=`, because the AMBIENT value is the hazard.
  def test_the_opt_out_disarms_it
    %w[off 0 false no].each do |value|
      refute armed_with("GIT_ISOLATION" => value), "#{value.inspect} must disarm the floor"
    end
    assert armed_with({}), "absent GIT_ISOLATION must leave the floor armed"
    assert armed_with("GIT_ISOLATION" => "on"), "any other value leaves it armed"
  end

  # THE COLLISION THIS DESIGN AVOIDS. credential_session_lifecycle_test.rb builds a
  # child env with GIT_CONFIG_COUNT=2; a process-wide numbered scheme would be
  # replaced wholesale by it. Assert we are not using those slots at all.
  def test_it_does_not_use_the_contended_numbered_slots
    source = File.read(PLUGIN)

    refute_match(/ENV\["GIT_CONFIG_COUNT"\]\s*=/, source,
                 "GIT_CONFIG_COUNT is already used as a child-env overlay elsewhere; " \
                 "a process-wide numbered scheme collides with it")
    assert_match(/ENV\["GIT_CONFIG_SYSTEM"\]\s*=/, source)
  end

  def test_the_generated_config_is_a_real_readable_file
    path = GitIsolationPlugin.config_path

    assert File.file?(path), "git reads GIT_CONFIG_SYSTEM as a PATH, so it must exist on disk"
    assert_match(/maintenance/, File.read(path))
  end

  private

  def armed_with(overrides)
    original = ENV.to_h
    overrides.each { |k, v| ENV[k] = v }
    ENV.delete("GIT_ISOLATION") if overrides.empty?
    GitIsolationPlugin.armed?
  ensure
    ENV.replace(original)
  end

  # A real repo, driven with the env THE PLUGIN ITSELF ARMED — not a hand-built
  # hash. An earlier version of this helper passed GIT_CONFIG_SYSTEM directly,
  # which meant it never exercised `arm!` at all: deleting the arming line left
  # every test green. Read the value out of ENV after arming, so the wiring is
  # part of what is under test.
  def in_repo
    Dir.mktmpdir("git-isolation") do |dir|
      armed = ENV["GIT_CONFIG_SYSTEM"]
      flunk "the plugin did not arm GIT_CONFIG_SYSTEM — nothing downstream can be isolated" if armed.to_s.empty?

      env = { "GIT_CONFIG_SYSTEM" => armed }
      git(dir, env, "init", "--quiet")
      yield dir, env
    end
  end

  def git(dir, env, *args)
    out, err, status = Open3.capture3(env, "git", "-C", dir, *args)
    flunk "git #{args.join(' ')} failed: #{err}" unless status.success? || args.include?("--get")
    out.strip
  end
end
