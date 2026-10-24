require "test_helper"

# Release::EngineConsumers picks the engine apps a release must re-lock even when
# they carry no card in it: the drift that left moms-app 14 and rantly 34 engine
# releases behind the hub on 2026-10-24.
class Release::EngineConsumersTest < ActiveSupport::TestCase
  App = Struct.new(:slug, :engine, :status, keyword_init: true) do
    def live? = AppCatalog::LIVE_STATUSES.include?(status)
  end

  REGISTRY = {
    "gems" => { "studio-engine" => { "ladder" => "three-rung" } },
    "apps" => {
      "mcritchie-studio" => { "ladder" => "three-rung" },
      "moms-app" => { "ladder" => "three-rung" },
      "dads-app" => { "ladder" => "three-rung" },
      "acquisition-studio" => { "ladder" => "three-rung" },
      "chain-ops" => { "ladder" => "blocked" }
    }
  }.freeze

  CATALOG = [
    App.new(slug: "mcritchie-studio", engine: true, status: "active"),
    App.new(slug: "moms-app", engine: true, status: "active"),
    App.new(slug: "dads-app", engine: false, status: "showcase"),
    App.new(slug: "acquisition-studio", engine: true, status: "archived"),
    App.new(slug: "chain-ops", engine: true, status: "active"),
    App.new(slug: "unregistered", engine: true, status: "active")
  ].freeze

  test "every live, sweepable engine app is a consumer, and nothing else is" do
    assert_equal %w[mcritchie-studio moms-app], Release::EngineConsumers.all(REGISTRY, CATALOG)
  end

  test "a cardless engine app is picked; a carried one is left to the swept loop" do
    assert_equal %w[moms-app], Release::EngineConsumers.cardless(REGISTRY, CATALOG, ["mcritchie-studio"])
  end

  test "the control: an engine: false app is never picked, carried or not" do
    refute_includes Release::EngineConsumers.cardless(REGISTRY, CATALOG, []), "dads-app"
    refute_includes Release::EngineConsumers.cardless(REGISTRY, CATALOG, ["mcritchie-studio"]), "dads-app"
  end

  test "an archived engine app, a parked ladder and a repo the release registry lacks are left alone" do
    picked = Release::EngineConsumers.cardless(REGISTRY, CATALOG, [])
    refute_includes picked, "acquisition-studio"
    refute_includes picked, "chain-ops"
    refute_includes picked, "unregistered"
  end

  test "a release that carries every engine app leaves nothing to re-lock" do
    assert_empty Release::EngineConsumers.cardless(REGISTRY, CATALOG, %w[mcritchie-studio moms-app])
  end

  # The live registries: the two apps that drifted are consumers, and an
  # engine-free showcase app is not.
  test "the real catalog and registry name moms-app and rantly, and not dads-app" do
    registry = YAML.load_file(Rails.root.join("config/release_repos.yml"))
    consumers = Release::EngineConsumers.all(registry, AppCatalog.apps)
    assert_includes consumers, "moms-app"
    assert_includes consumers, "rantly"
    assert_includes consumers, "mcritchie-studio"
    refute_includes consumers, "dads-app"
    refute_includes consumers, "acquisition-studio"
  end
end
