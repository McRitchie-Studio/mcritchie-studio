# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [unit] MarketingKit::Spec — the worked example loads, and each kind of bad
# spec fails on load with a message naming what to fix, before any rendering.
class MarketingKitSpecTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  test "the worked example loads with its colours, logos and photos" do
    load_kit do |spec|
      assert_equal "RF", spec.short
      assert_equal "#2F6B4F", spec.colour(:primary)
      assert_equal "#E8955A", spec.colour(:accent_on_dark)
      assert_equal "Brand Kit: Ridgeline Fabrication", spec.root_name
      assert File.file?(spec.logo_png(:full, :dark))
      assert_includes spec.logo_files.map(&:last), "RF_logo_full_light.svg"
      assert_equal "RF_photo_shop-floor.jpg", spec.photo_name("shop-floor.jpg")
    end
  end

  test "an optional colour falls back to the one it deepens" do
    load_kit(edit: ->(d) { d["palette"].reject! { |c| %w[accent_on_dark primary_deep].include?(c["key"]) } }) do |spec|
      assert_equal spec.colour(:accent), spec.colour(:accent_on_dark)
      assert_equal spec.colour(:primary), spec.colour(:primary_deep)
    end
  end

  test "title is optional: it falls back to primary, and a title key is taken as given" do
    load_kit do |spec|
      refute(spec.palette.any? { |c| c[:key] == "title" }, "the worked example sets no title")
      assert_equal "#2F6B4F", spec.colour(:title)
    end
    with_title = ->(d) { d["palette"] << { "key" => "title", "name" => "Forge", "hex" => "#c8661f", "role" => "Titles" } }
    load_kit(edit: with_title) do |spec|
      assert_equal "#C8661F", spec.colour(:title)
      assert_equal "#2F6B4F", spec.colour(:primary), "primary keeps its own colour for bars and tables"
    end
  end

  test "one swatch can carry two keys, and still counts each key once" do
    shared = ->(d) { d["palette"].find { |c| c["key"] == "accent" }["key"] = %w[accent title] }
    load_kit(edit: shared) do |spec|
      assert_equal "#C8702E", spec.colour(:title)
      assert_equal "#C8702E", spec.colour(:accent)
      assert_equal 6, spec.palette.size, "the copper swatch is shown once"
    end
    twice = ->(d) { d["palette"].find { |c| c["key"] == "accent" }["key"] = %w[accent primary] }
    with_kit(edit: twice) { |path| assert_match(/palette key used twice/, assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }.message) }
    unknown = ->(d) { d["palette"].find { |c| c["key"] == "accent" }["key"] = %w[accent headline] }
    with_kit(edit: unknown) { |path| assert_match(/unknown palette key headline/, assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }.message) }
  end

  test "a brand key names the /logos brand, and the owner is drive.subject" do
    load_kit { |spec| assert_nil spec.logo_brand }
    load_kit(edit: ->(d) { d["brand"] = "welding_v2" }) do |spec|
      assert_equal "welding_v2", spec.logo_brand
      assert_equal "team@mcritchie.studio", spec.owner
    end
  end

  test "a photo slot left out uses the cover" do
    load_kit { |spec| assert_equal spec.photo_path("shop-floor.jpg"), spec.slot(:slide_quote) }
  end

  {
    "missing tagline" => [->(d) { d.delete("tagline") }, /missing tagline/],
    "bad short" => [->(d) { d["short"] = "R F" }, /short must be/],
    "no drive subject" => [->(d) { d["drive"].delete("subject") }, /drive.subject/],
    "bad hex" => [->(d) { d["palette"][0]["hex"] = "green" }, /#RRGGBB/],
    "no accent key" => [->(d) { d["palette"].reject! { |c| c["key"] == "accent" } }, /needs accent/],
    "unknown key" => [->(d) { d["palette"][5]["key"] = "secondary" }, /unknown palette key secondary/],
    "too many swatches" => [->(d) { d["palette"] += Array.new(3) { |i| { "name" => "X#{i}", "hex" => "#000000" } } }, /at most 8/],
    "unlisted favourite" => [->(d) { d["photos"]["favourites"] << "ghost.jpg" }, /not listed in photos.items: ghost.jpg/],
    "unknown slot" => [->(d) { d["photos"]["slots"]["hero"] = "shop-floor.jpg" }, /unknown photo slot hero/],
    "no cover slot" => [->(d) { d["photos"]["slots"].delete("cover") }, /slots.cover is required/],
    "brand not on /logos" => [->(d) { d["brand"] = "nike" }, /brand nike is not a \/logos brand/],
    "a share domain that is a URL" => [->(d) { d["drive"]["share_domains"] = ["https://example.com"] }, /plain domains .*https:\/\/example.com/],
    "a share domain that is an address" => [->(d) { d["drive"]["share_domains"] = ["owner@example.com"] }, /plain domains .*owner@example.com/],
    "share domains not a list" => [->(d) { d["drive"]["share_domains"] = "example.com" }, /share_domains must be a list/]
  }.each do |label, (edit, message)|
    test "refuses a spec with #{label}" do
      with_kit(edit: edit) do |path|
        error = assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }
        assert_match message, error.message
      end
    end
  end

  test "share_domains reads lowercased, and a spec without it shares with no domain" do
    load_kit(edit: ->(d) { d["drive"]["share_domains"] = ["Example.COM", "mcritchie.studio"] }) do |spec|
      assert_equal %w[example.com mcritchie.studio], spec.share_domains
    end
    load_kit(edit: ->(d) { d["drive"].delete("share_domains") }) { |spec| assert_empty spec.share_domains }
  end

  test "a root_name in the spec overrides the Brand Kit default" do
    load_kit(edit: ->(d) { d["drive"]["root_name"] = "Ridgeline Kit" }) { |spec| assert_equal "Ridgeline Kit", spec.root_name }
  end

  test "refuses a spec whose required logo file is missing" do
    with_kit(skip: ["horizontal_dark"]) do |path|
      error = assert_raises(MarketingKit::Error) { MarketingKit::Spec.load(path) }
      assert_match %r{missing logo files logos/png/horizontal_dark.png}, error.message
    end
  end

  test "refuses a path with no spec" do
    assert_raises(MarketingKit::Error) { MarketingKit::Spec.load("/nonexistent/kit.yml") }
  end
end
