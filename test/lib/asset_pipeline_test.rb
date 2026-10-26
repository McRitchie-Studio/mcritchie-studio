require "test_helper"

# The hub serves its assets through Propshaft (moved off Sprockets 2026-10-25,
# task hub-moves-to-propshaft; the recipe is rolio's docs/RUNBOOK.md "Asset
# pipeline (Propshaft)"). This guard fails if Sprockets, or a piece of its
# configuration that Propshaft silently ignores, comes back.
#
# Why a guard and not just "the suite is green": every Sprockets-only knob is a
# NO-OP under Propshaft, not an error. A `//= link` manifest, a `*= require_tree`
# directive or `config.assets.precompile += …` boots fine and does nothing, so a
# stylesheet the directive used to pull in simply stops reaching the browser.
class AssetPipelineTest < ActiveSupport::TestCase
  ROOT = Rails.root

  test "[unit] the bundle carries propshaft and not sprockets" do
    gemfile = ROOT.join("Gemfile").read
    lock = ROOT.join("Gemfile.lock").read

    assert_match(/^gem "propshaft"/, gemfile)
    assert_match(/^    propshaft \(1\.3\.2\)/, lock, "propshaft is pinned to 1.3.2, matching rolio and cyvasse")
    refute_match(/^\s*gem ["']sprockets/, gemfile, "Gemfile names sprockets again")
    refute_match(/^\s+sprockets(-rails)? \(/, lock, "Gemfile.lock resolves sprockets again")
  end

  test "[unit] the running app's asset pipeline is propshaft" do
    assert_kind_of Propshaft::Assembly, Rails.application.assets
    refute defined?(::Sprockets), "Sprockets is loaded into the process"
  end

  test "[unit] no sprockets manifest or directive is left in app/assets" do
    refute ROOT.join("app/assets/config/manifest.js").exist?,
           "app/assets/config/manifest.js is Sprockets-only; Propshaft serves every file on the load path"

    directives = Dir[ROOT.join("app/assets/**/*.{css,js}")].select do |path|
      File.read(path).match?(%r{^\s*(\*=|//=)\s*(require|link)})
    end
    assert_empty directives.map { |p| Pathname(p).relative_path_from(ROOT).to_s },
                 "Sprockets directives are inert under Propshaft; link the file from the layout instead"
  end

  # studio-engine's shared head links both by name; a missing one raises at render.
  test "[unit] the stylesheets the engine head links by name exist" do
    %w[application.css tailwind.css].each do |name|
      refute_nil Rails.application.assets.load_path.find(name), "#{name} is gone from the load path"
    end
  end

  test "[unit] config sets no sprockets-only asset option" do
    sprockets_only = /config\.assets\.(precompile|compile|css_compressor|js_compressor|debug|digest|unknown_asset_fallback)\b|Sprockets\./
    offenders = Dir[ROOT.join("config/**/*.rb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?("#")

        "#{Pathname(path).relative_path_from(ROOT)}:#{i + 1}" if line.match?(sprockets_only)
      end
    end
    assert_empty offenders, "Propshaft ignores these settings, and Sprockets is not loaded"
  end

  # Rails' Mime registry knows no AVIF; Propshaft types an asset from it.
  test "[unit] an avif asset is typed image/avif" do
    asset = Rails.application.assets.load_path.find("hero/denver-hero-1280.avif")
    refute_nil asset, "the hero avif left the load path"
    assert_equal "image/avif", asset.content_type.to_s
    assert_equal "image/avif", Rack::Mime.mime_type(".avif")
  end
end
