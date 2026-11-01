require "test_helper"

# [integration] The /build name check refuses every name the app catalog (AppCatalog::PATH) holds
# (task preview-domain-mcritchie-app). A library (studio-engine, turf-vault and
# its alias vault) and a host satellites.yml never lists (tax-studio's tax.mcritchie.studio host) have no App row in this database,
# so only the catalog can refuse them: the live availability probe the name
# field calls, through the real routes, answers "reserved", while a fresh name
# stays available.
class BuildCatalogNamesTest < ActionDispatch::IntegrationTest
  CATALOG_ONLY = %w[studio-engine solana-studio turf-vault vault tax].freeze

  test "the availability probe refuses app catalog names that have no App row" do
    assert_empty App.where(slug: CATALOG_ONLY).pluck(:slug), "the catalog, not an App row, must be what refuses"
    CATALOG_ONLY.each do |name|
      get build_check_path, params: { subdomain: name.upcase }
      assert_response :success
      assert_equal({ "subdomain" => name, "available" => false, "reason" => "That name is reserved." },
                   response.parsed_body, name)
    end

    get build_check_path, params: { subdomain: "engine-room-cafe" }
    assert_equal true, response.parsed_body["available"]
  end
end
