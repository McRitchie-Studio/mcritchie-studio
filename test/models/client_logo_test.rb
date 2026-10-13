require "test_helper"

# [unit] ClientLogo — a client's own logo, read from its workspace's `logo:` in
# config/workspace_icons.yml: a brand of the logo studio (config/logo_brands.yml),
# drawn as that brand's kit icon in light and dark, or, for a client the studio
# has no brand for yet, a mark filed in the hub's brand assets. Never the
# 1Password vault icon.
class ClientLogoTest < ActiveSupport::TestCase
  # The six clients /stack and /stack/matrix draw (db/seeds/60_stack_clients.rb).
  CLIENTS = %w[studio industries commercial-welding turf-monster cyvasse 10and5].freeze

  test "each stack client resolves a logo from the brand source" do
    logos = ClientLogo.for_all(CLIENTS)

    CLIENTS.each do |slug|
      logo = logos.fetch(slug)
      assert logo, "#{slug} has no logo: give its workspace a logo: in config/workspace_icons.yml"
      assert_equal slug, logo.slug
    end
  end

  test "a client with a logo-studio brand draws that brand's kit icon in both tones" do
    { "studio" => "studio", "industries" => "industries", "turf-monster" => "turf", "commercial-welding" => "welding" }.each do |slug, brand|
      logo = ClientLogo.for(slug)

      assert_equal :brand, logo.source, slug
      assert_equal brand, logo.brand, slug
      assert_equal %i[light dark], logo.variants.keys, "#{slug} carries a light and a dark logo"
      logo.variants.each do |tone, variant|
        assert_equal :icon, variant.type
        assert_equal tone, variant.tone
        assert_equal brand, variant.logo.brand
        assert_match(/\A<svg/, variant.svg, "#{slug} #{tone} draws")
      end
    end
  end

  test "with no kit icon saved, a brand with original art shows its original, not the flat alt" do
    industries = ClientLogo.for("industries").variants.fetch(:light)

    assert_equal :original, industries.colouring, "McRitchie Industries shows its real, steel-gradient icon"
    assert_equal :alt, ClientLogo.for("studio").variants.fetch(:light).colouring, "Studio's logo is solid colour: alt only"
  end

  test "a saved kit icon is the logo the client shows" do
    BrandKit.for("industries").save_choice(:icon, { colouring: "alt" }, by: "alex@mcritchie.studio")

    assert_equal :alt, ClientLogo.for("industries").variants.fetch(:dark).colouring
  end

  test "a client with no logo-studio brand shows the mark filed in the hub's brand assets" do
    %w[cyvasse 10and5].each do |slug|
      logo = ClientLogo.for(slug)

      assert_equal :file, logo.source, slug
      assert_equal "client_logos/#{slug}.svg", logo.file
      assert Rails.root.join("app/assets/images", logo.file).file?, "#{slug}'s mark is a hub asset, not a link into its app"
    end
  end

  test "a workspace without a logo has none, and an unresolvable entry is refused" do
    assert_nil ClientLogo.for("family")
    assert_nil ClientLogo.for("atlantis")

    assert_raises(ClientLogo::Error) { ClientLogo.new("x", { "brand" => "atlantis" }) }
    assert_raises(ClientLogo::Error) { ClientLogo.new("x", { "file" => "client_logos/none.svg" }) }
    assert_raises(ClientLogo::Error) { ClientLogo.new("x", { "file" => "../../config/master.key" }) }
    assert_raises(ClientLogo::Error) { ClientLogo.new("x", { "brand" => "studio", "file" => "client_logos/cyvasse.svg" }) }
  end

  test "every logo: in config/workspace_icons.yml resolves" do
    WorkspaceIconConfig.workspaces.each do |slug, workspace|
      next unless workspace.key?("logo")

      assert ClientLogo.for(slug), "#{slug}'s logo: does not resolve"
    end
  end

  test "for_all reads every brand kit in one query" do
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?("brand_kits") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ClientLogo.for_all(CLIENTS) }

    assert_equal 1, queries
  end
end
