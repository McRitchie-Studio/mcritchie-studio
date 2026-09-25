# frozen_string_literal: true

# Unit tests for bin/lib/release_registry.rb — what config/release_repos.yml
# DECLARES about a repo's test lane, read by bin/fast-check.
#
#   ruby -Itest test/lib/release_registry_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/release_registry"

class ReleaseRegistryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def registry
    @registry ||= YAML.safe_load_file(File.join(ROOT, "config/release_repos.yml"))
  end

  def test_the_gems_declare_their_own_gate
    %w[studio-engine solana-studio].each do |gem|
      assert ReleaseRegistry.gem_repo?(gem), "#{gem} is filed under gems:"
      assert ReleaseRegistry.registry_gated?(gem)
      assert_equal "bin/release-check", ReleaseRegistry.release_check_cmd(gem),
                   "#{gem}'s row names the command that IS its suite"
    end
  end

  def test_registry_gated_is_keyed_on_the_declaration_not_the_section
    # turf-vault is an `apps` row that DECLARES a release_check — the case that
    # keying on the gems section alone left with no lane at all (2026-09-14).
    refute ReleaseRegistry.gem_repo?("turf-vault")
    assert ReleaseRegistry.registry_gated?("turf-vault"),
           "an apps row that declares release_check runs it as its whole lane"
    assert_equal "bin/release-check", ReleaseRegistry.release_check_cmd("turf-vault")
  end

  def test_a_rails_app_that_declares_nothing_keeps_the_rails_lanes
    %w[mcritchie-studio turf-monster].each do |app|
      refute ReleaseRegistry.gem_repo?(app)
      refute ReleaseRegistry.registry_gated?(app), "#{app} owes the ordinary Rails lanes"
      assert_nil ReleaseRegistry.release_check_cmd(app)
    end
  end

  def test_an_unknown_or_blank_repo_fails_closed
    ["", nil, "no-such-repo"].each do |repo|
      refute ReleaseRegistry.gem_repo?(repo)
      refute ReleaseRegistry.registry_gated?(repo)
      assert_nil ReleaseRegistry.release_check_cmd(repo)
    end
  end

  def test_the_answers_agree_with_the_registry_on_disk
    %w[apps gems].each do |section|
      (registry[section] || {}).each do |slug, row|
        next unless row.is_a?(Hash)

        declared = row["release_check"].to_s.strip
        if declared.empty?
          assert_nil ReleaseRegistry.release_check_cmd(slug), "#{slug}: declares no release_check"
        else
          assert_equal declared, ReleaseRegistry.release_check_cmd(slug), "#{slug}: release_check read wrong"
        end
        assert_equal section == "gems", ReleaseRegistry.gem_repo?(slug), "#{slug}: section read wrong"
      end
    end
  end
end
