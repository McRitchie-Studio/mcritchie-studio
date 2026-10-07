# frozen_string_literal: true

# [unit] The GitHub App ids live in config/github_apps.yml, and bin/gh-app-mint-token
# reads them from there when GH_APP_IDENTITY names a row. That is what lets the
# hand-mint fallback for a 1Password outage run without 1Password: the id is in the
# checkout, and the docs cite the file instead of copying the numbers.
#
# Standalone: ruby -Itest test/lib/github_apps_config_test.rb

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "yaml"

class GithubAppsConfigTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONFIG = File.join(ROOT, "config/github_apps.yml")
  MINTER = File.join(ROOT, "bin/gh-app-mint-token")

  def apps = YAML.safe_load_file(CONFIG)

  def mint(env)
    Open3.capture3({ "GH_APP_ID" => nil, "GH_APP_IDENTITY" => nil }.merge(env), RbConfig.ruby, MINTER)
  end

  def test_each_identity_has_a_numeric_app_id_and_its_1password_item
    assert_equal %w[agent deployer], apps.keys.sort
    apps.each do |identity, row|
      assert_match(/\A\d{6,9}\z/, row.fetch("app_id").to_s, "#{identity} needs a numeric app id")
      assert_match(/\Agithub\./, row.fetch("item"), "#{identity} names its 1Password item")
    end
    refute_equal apps["agent"]["app_id"], apps["deployer"]["app_id"],
                 "the agent and deployer are separate identities with different grants"
  end

  # The control: the minter resolves the id from the file. A bad PEM is the next
  # refusal it reaches, so reaching it proves the id was found, with no network.
  def test_the_minter_reads_the_app_id_for_a_named_identity
    _out, err, status = mint("GH_APP_IDENTITY" => "agent", "GH_APP_PEM" => "not a key")

    refute status.success?
    assert_match(/GH_APP_PEM is not a valid RSA private key/, err)
  end

  def test_the_minter_refuses_an_identity_the_file_does_not_name
    _out, err, status = mint("GH_APP_IDENTITY" => "nobody", "GH_APP_PEM" => "x")

    refute status.success?
    assert_match(/GH_APP_IDENTITY "nobody" is not one of agent, deployer/, err)
  end

  def test_the_minter_still_refuses_with_neither_id_nor_identity
    _out, err, status = mint("GH_APP_PEM" => "x")

    refute status.success?
    assert_match(/GH_APP_ID or GH_APP_IDENTITY is required/, err)
  end
end
