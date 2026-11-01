# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# [unit] MarketingKit::LogoPngs — `bin/marketing-kit pngs DIR` draws each logo at
# its SVG's own shape: a horizontal logo stays wide (script/brand_png.cjs squared
# one, 2026-10-31), icons are square with the mark fitted inside, icon_light also
# yields icon_512.png, and an SVG without a kit name is skipped, never guessed.
# [integration] With Chrome present, a wide SVG renders to a PNG whose header
# carries the planned size.
class MarketingKitPngsTest < ActiveSupport::TestCase
  WIDE_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3000 300"><rect width="3000" height="300" fill="#C8661F"/></svg>'
  TALL_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 500"><rect width="400" height="500"/></svg>'

  def with_logos(files)
    Dir.mktmpdir("kit-pngs") do |dir|
      FileUtils.mkdir_p(File.join(dir, "logos", "svg"))
      files.each { |name, svg| File.write(File.join(dir, "logos", "svg", "#{name}.svg"), svg) }
      yield dir
    end
  end

  test "the size keeps the SVG's shape, from its viewBox" do
    assert_equal [2000, 200], MarketingKit::LogoPngs.size(WIDE_SVG, 2000)
    assert_equal [2000, 2500], MarketingKit::LogoPngs.size(TALL_SVG, 2000)
    error = assert_raises(MarketingKit::Error) { MarketingKit::LogoPngs.size('<svg width="10" height="10"></svg>', 2000) }
    assert_match "viewBox", error.message
  end

  test "the plan draws wide logos 2000 wide, icons 512 square, and icon_512 from icon_light" do
    with_logos("horizontal_light" => WIDE_SVG, "icon_light" => TALL_SVG, "icon_dark" => TALL_SVG) do |dir|
      plan = MarketingKit::LogoPngs.plan(dir).map { |_, png, w, h| [File.basename(png), w, h] }
      assert_equal [["horizontal_light.png", 2000, 200], ["icon_dark.png", 512, 512],
                    ["icon_light.png", 512, 512], ["icon_512.png", 512, 512]], plan
    end
  end

  test "an SVG without a kit name gets no PNG and is named as skipped" do
    with_logos("stacked-light" => TALL_SVG, "watermark" => WIDE_SVG, "full_dark" => TALL_SVG) do |dir|
      assert_equal ["full_dark.png"], MarketingKit::LogoPngs.plan(dir).map { |row| File.basename(row[1]) }
      assert_equal ["stacked-light.svg", "watermark.svg"], MarketingKit::LogoPngs.skipped(dir)
    end
  end

  test "drawing a folder with no kit-named SVGs fails with the folder named" do
    with_logos({}) do |dir|
      error = assert_raises(MarketingKit::Error) { MarketingKit::LogoPngs.draw(dir) }
      assert_match "logos/svg", error.message
    end
  end

  test "Chrome renders a wide logo at its planned size" do
    skip "Chrome not at #{MarketingKit::ChromePdf::CHROME}" unless File.executable?(MarketingKit::ChromePdf::CHROME)

    with_logos("horizontal_dark" => WIDE_SVG) do |dir|
      MarketingKit::LogoPngs.draw(dir)
      header = File.binread(File.join(dir, "logos", "png", "horizontal_dark.png"), 24)
      assert_equal "\x89PNG".b, header[0, 4]
      assert_equal [2000, 200], header[16, 8].unpack("NN")
    end
  end
end
