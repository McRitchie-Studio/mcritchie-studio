# frozen_string_literal: true

# [unit] Devops::GoogleOAuthClients — the production client-id list
# (config/google_oauth_clients.yml) and the one rule on it: a development or
# test boot never signs in with a production Google client. Rails-free.
#
#   ruby -Itest test/lib/google_oauth_clients_test.rb
require "minitest/autorun"
require "tmpdir"
require_relative "../../app/models/devops/google_oauth_clients"

class GoogleOAuthClientsTest < Minitest::Test
  HUB = "999864627557-9sol5d7l7hnmonhth33d180k068mf0b8.apps.googleusercontent.com"
  DEV = "999864627557-devdevdevdevdevdevdevdevdevdevdev.apps.googleusercontent.com"

  def test_the_shipped_file_lists_the_hub_turf_and_tax_studio_clients
    apps = Devops::GoogleOAuthClients.production
    assert_equal %w[mcritchie-studio tax-studio turf-monster-mainnet], apps.keys.sort
    assert_equal apps["mcritchie-studio"], apps["tax-studio"], "the hub and tax-studio share one client"
    apps.each_value { |id| assert_match(/\A\d+-[a-z0-9]+\.apps\.googleusercontent\.com\z/, id) }
  end

  def test_a_production_id_names_every_app_that_holds_it_and_a_dev_id_names_none
    assert_equal %w[mcritchie-studio tax-studio], Devops::GoogleOAuthClients.apps_for(HUB)
    assert Devops::GoogleOAuthClients.production?(" #{HUB} ")
    assert_empty Devops::GoogleOAuthClients.apps_for(DEV)
    refute Devops::GoogleOAuthClients.production?(DEV)
    refute Devops::GoogleOAuthClients.production?(nil)
  end

  def refuse!(client_id:, client_secret: "GOCSPX-some-secret", env: "development")
    Devops::GoogleOAuthClients.refuse_production_in_development!(client_id: client_id, client_secret: client_secret, env: env)
  end

  def test_a_production_client_with_its_secret_in_development_or_test_refuses_and_names_the_remedy
    %w[development test].each do |env|
      error = assert_raises(Devops::GoogleOAuthClients::ProductionClientInDevelopment, env) { refuse!(client_id: HUB, env: env) }
      assert_includes error.message, "mcritchie-studio and tax-studio"
      assert_includes error.message, "bin/dev-google-client --write"
    end
  end

  def test_controls_the_dev_client_a_blank_id_a_production_id_with_no_secret_and_production_itself_all_pass
    assert_nil refuse!(client_id: DEV)
    assert_nil refuse!(client_id: nil)
    assert_nil refuse!(client_id: "", env: "test")
    assert_nil refuse!(client_id: HUB, client_secret: nil), "the id alone cannot sign in as production"
    assert_nil refuse!(client_id: HUB, client_secret: "  ")
    assert_nil refuse!(client_id: HUB, env: "production")
  end

  def test_a_file_with_no_production_block_does_not_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "clients.yml")
      File.write(path, "development: {}\n")
      assert_raises(KeyError) { Devops::GoogleOAuthClients.production(path) }
    end
  end
end
