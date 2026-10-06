# frozen_string_literal: true

# [unit] AppCatalog, the loader for config/apps.yml: it validates tiers,
# statuses, unique slugs, ports and glyphs, refuses a record with a missing or
# unknown field, and hands out frozen values.

require "minitest/autorun"
require_relative "../../lib/app_catalog"

class AppCatalogTest < Minitest::Test
  APP = {
    "slug" => "demo-app", "name" => "Demo App", "emoji" => "🧪", "color" => "#123456",
    "tier" => "basic", "status" => "active", "port" => 5000, "repo" => "McRitchie-Studio/demo-app",
    "heroku_app" => "demo-app", "production_url" => "https://demo.example", "qa_url" => nil,
    "engine" => false, "hosted" => true, "workspace" => nil, "description" => "A demo"
  }.freeze
  LIBRARY = { "slug" => "demo-gem", "name" => "Demo Gem", "emoji" => "💠", "color" => "#654321",
              "aliases" => ["gem-alias"], "description" => "A gem" }.freeze

  def yaml(apps: [APP], libraries: [LIBRARY]) = YAML.dump("apps" => apps, "libraries" => libraries)

  def parse(**) = AppCatalog.parse(yaml(**))

  def refusal(**)
    error = assert_raises(AppCatalog::Invalid) { parse(**) }
    error.message
  end

  def test_the_real_catalog_loads_and_is_frozen
    catalog = AppCatalog.parse(File.read(AppCatalog::PATH))
    assert catalog.apps.frozen?
    assert catalog.apps.all?(&:frozen?)
    assert catalog.apps.first.slug.frozen?
    assert_equal "mcritchie-studio", catalog.apps.first.slug
  end

  def test_alex_s_tiers_and_statuses_are_recorded
    tiers = AppCatalog.apps.to_h { |app| [app.slug, [app.tier, app.status]] }
    assert_equal ["studio", "active"], tiers.fetch("mcritchie-studio")
    %w[turf-monster cyvasse].each { |slug| assert_equal ["product", "showcase"], tiers.fetch(slug) }
    %w[mcritchie-industries commercial-welding].each { |slug| assert_equal ["product", "active"], tiers.fetch(slug) }
    assert_equal ["basic", "active"], tiers.fetch("moms-app")
    %w[dads-app rantly 10and5 portfolio prisoners-dilemma search-position weekly-lock].each do |slug|
      assert_equal ["basic", "showcase"], tiers.fetch(slug), slug
    end
    %w[rolio chain-ops tax-studio acquisition-studio].each { |slug| assert_equal [nil, "archived"], tiers.fetch(slug), slug }
    assert_equal false, AppCatalog.app("commercial-welding").hosted
    assert_nil AppCatalog.app("tax-studio").repo
  end

  def test_a_valid_catalog_parses_into_entries
    catalog = parse
    app = catalog.apps.first
    assert_equal "demo-app", app.slug
    assert_equal 5000...5100, app.port_range
    assert app.live?
    assert_equal "Basic", app.tier_label
    assert_equal ["gem-alias"], catalog.libraries.first.aliases
  end

  def test_tier_and_status_must_be_known
    assert_match(/tier "gold" is not one of studio, product, basic/, refusal(apps: [APP.merge("tier" => "gold")]))
    assert_match(/status "live" is not one of active, delinquent, showcase, archived/,
                 refusal(apps: [APP.merge("status" => "live")]))
  end

  def test_a_null_tier_is_allowed_only_when_archived
    assert_match(/tier nil/, refusal(apps: [APP.merge("tier" => nil)]))
    assert_nil parse(apps: [APP.merge("tier" => nil, "status" => "archived")]).apps.first.tier
  end

  def test_slugs_ports_glyphs_and_workspaces_are_unique
    twin = APP.merge("port" => 5100, "emoji" => "🧫")
    assert_match(/slug demo-app appears more than once/, refusal(apps: [APP, twin]))
    alias_clash = LIBRARY.merge("aliases" => ["demo-app"])
    assert_match(/slug demo-app appears more than once/, refusal(libraries: [alias_clash]))
    port_clash = APP.merge("slug" => "other-app", "emoji" => "🧫")
    assert_match(/port 5000 belongs to more than one app/, refusal(apps: [APP, port_clash]))
    glyph_clash = APP.merge("slug" => "other-app", "port" => 5100)
    assert_match(/emoji 🧪 belongs to more than one app/, refusal(apps: [APP, glyph_clash]))
    ws = { "workspace" => "studio" }
    ws_clash = APP.merge("slug" => "other-app", "port" => 5100, "emoji" => "🧫", **ws)
    assert_match(/workspace studio belongs to more than one app/, refusal(apps: [APP.merge(ws), ws_clash]))
  end

  def test_two_portless_apps_do_not_clash
    portless = APP.merge("port" => nil)
    other = portless.merge("slug" => "other-app", "emoji" => "🧫")
    assert_equal 2, parse(apps: [portless, other]).apps.size
  end

  def test_a_port_must_start_a_block
    assert_match(/port must be null or a multiple of 100/, refusal(apps: [APP.merge("port" => 5001)]))
  end

  def test_every_field_is_required_and_no_other
    assert_match(/app demo-app is missing hosted/, refusal(apps: [APP.except("hosted")]))
    assert_match(/app demo-app has unknown tagline/, refusal(apps: [APP.merge("tagline" => "x")]))
    assert_match(/library demo-gem is missing aliases/, refusal(libraries: [LIBRARY.except("aliases")]))
  end

  def test_flags_colors_and_urls_are_typed
    assert_match(/engine must be true or false/, refusal(apps: [APP.merge("engine" => "yes")]))
    assert_match(/color must be #RRGGBB/, refusal(apps: [APP.merge("color" => "purple")]))
    assert_match(/qa_url must be null or an https URL/, refusal(apps: [APP.merge("qa_url" => "http://qa.example")]))
  end

  def test_every_problem_is_named_at_once
    message = refusal(apps: [APP.merge("tier" => "gold", "color" => "x")])
    assert_match(/tier "gold"/, message)
    assert_match(/color must be/, message)
  end

  def test_unparseable_yaml_is_refused_as_invalid
    assert_raises(AppCatalog::Invalid) { AppCatalog.parse("apps: [") }
    assert_raises(AppCatalog::Invalid) { AppCatalog.parse("- just a list") }
  end

  def test_derived_maps_cover_apps_libraries_and_aliases
    map = AppCatalog.emoji_map
    assert map.frozen?
    assert_equal "🐊", map.fetch("turf-monster")
    assert_equal map.fetch("turf-vault"), map.fetch("vault"), "an alias shares its library's glyph"
    AppCatalog.apps.each { |app| assert_equal app.emoji, map.fetch(app.slug) }

    groups = AppCatalog.release_groups
    assert_equal AppCatalog.apps.map(&:slug) + AppCatalog.libraries.map(&:slug), groups.map { |g| g[:key] }
    assert_includes groups.find { |g| g[:key] == "turf-vault" }[:aliases], "vault"

    rows = AppCatalog.seed_rows
    assert_equal (0...rows.size).to_a, rows.map { |row| row[:position] }
    assert_equal "showcase", rows.find { |row| row[:slug] == "cyvasse" }[:status]
  end

  def test_for_workspace_finds_the_stack_client_s_app
    assert_equal "mcritchie-studio", AppCatalog.for_workspace("studio").slug
    assert_equal "mcritchie-industries", AppCatalog.for_workspace("industries").slug
    assert_nil AppCatalog.for_workspace("family")
  end
end
