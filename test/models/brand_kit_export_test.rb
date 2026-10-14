# frozen_string_literal: true

require "test_helper"

# [unit] BrandKitExport (task kit-export-and-clear-lens): a brand's kit as the files an app takes its logo from. Each
# file is the Kit card's logo (BrandKit#variant) in one tone; the README names every file, the palette, the typefaces
# and who saved the kit when; the zip holds them all in one folder.
class BrandKitExportTest < ActiveSupport::TestCase
  BASE = "https://hub.test"

  def export(brand, saver: nil) = BrandKitExport.new(BrandKit.for(brand), base_url: BASE, saver:)

  def entries(bytes)
    ZipKit::FileReader.read_zip_structure(io: StringIO.new(bytes)).to_h do |entry|
      [entry.filename, entry.extractor_from(StringIO.new(bytes)).extract.force_encoding(Encoding::UTF_8)]
    end
  end

  test "the files are every saved type in every tone, by a stable name" do
    assert_equal %w[icon-light.svg icon-dark.svg icon-watermark.svg navbar-light.svg navbar-dark.svg navbar-watermark.svg
                    stacked-light.svg stacked-dark.svg stacked-watermark.svg], BrandKitExport::FILES.keys
    assert BrandKitExport.file?("navbar-dark.svg")
    refute BrandKitExport.file?("navbar-sepia.svg")
    refute BrandKitExport.file?("../navbar-dark.svg")
    error = assert_raises(BrandKit::Error) { export("welding_v2").svg("README.md") }
    assert_match(/unknown kit file "README.md"/, error.message)
  end

  test "each file is the Kit card's logo in that tone: the saved choice, with the kit icon" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:navbar, { rule: "4", text: "homogeneous", colouring: "original" }, by: "alex@test.com")
    files = BrandKitExport.new(kit.reload, base_url: BASE)
    BrandKitExport::FILES.each do |name, (type, tone)|
      assert_equal kit.variant(type, tone:).svg, files.svg(name), name
    end
    assert_equal Logos::Variant.new(Logos::NavbarLogo.new("welding_v2"), rule: 4, text: :homogeneous, tone: :dark, colouring: :original).svg,
                 files.svg("navbar-dark.svg"), "Alex's saved Navbar: Original, homogeneous, rule of 4"
  end

  # Task stacked-rule-of-three: the export draws the saved proportion.
  test "a stacked choice saved in the rule of three is exported in it" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:stacked, { form: "two_line", proportion: "rule_of_three", text: "first", colouring: "original" }, by: "alex@test.com")
    files = BrandKitExport.new(kit.reload, base_url: BASE)
    assert_equal Logos::Variant.new(Logos::StackedLogo.new("welding_v2"), type: :stacked, form: :two_line, proportion: :rule_of_three, text: :first,
                                                                          tone: :dark, colouring: :original).svg,
                 files.svg("stacked-dark.svg")
    refute_equal Logos::StackedLogo.new("welding_v2").svg(text: :first, tone: :dark, colouring: :original), files.svg("stacked-dark.svg")
  end

  test "an unsaved brand exports its defaults and says so" do
    readme = export("studio").readme
    assert_includes readme, "# McRitchie Studio: logo kit"
    assert_includes readme, "Nothing saved yet: every file is the brand's default."
    assert_includes readme, "| navbar-dark.svg | default | McRitchie Studio navbar logo, rule of 4, second word leads, dark (for a dark background) |"
    assert_equal BrandKit.for("studio").variant(:navbar, tone: :dark).svg, export("studio").svg("navbar-dark.svg")
  end

  test "the README names every file, saved or default, the palette, the typefaces, the saver and the stable URLs" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:navbar, { rule: "4", text: "homogeneous", colouring: "original" }, by: "alex@test.com")
    readme = BrandKitExport.new(kit.reload, base_url: "#{BASE}/", saver: "Alex McRitchie").readme
    assert_includes readme, "Kit saved #{kit.updated_at.utc.strftime('%Y-%m-%d %H:%M UTC')} by Alex McRitchie."
    assert_includes readme, "| navbar-dark.svg | saved | Commercial Welding v2 navbar logo, rule of 4, homogeneous, dark, original colouring (for a dark background) |"
    assert_includes readme, "| stacked-light.svg | default |"
    assert_includes readme, "| icon-watermark.svg | default | Commercial Welding v2 icon, watermark (one colour, slightly transparent) |"
    assert_includes readme, "- Welding Blue #2D5E8E"
    assert_includes readme, "- Tagline: Montserrat Medium"
    assert_includes readme, "- https://hub.test/logos/welding_v2/kit/navbar-dark.svg"
    assert_includes readme, "- https://hub.test/logos/welding_v2/kit.zip (this whole kit)"
    assert_includes BrandKitExport.new(kit, base_url: BASE).readme, "by alex.", "with no named saver, the email's local part"
  end

  test "the zip holds the README and every file in one folder, byte for byte" do
    files = export("welding_v2")
    zipped = entries(files.zip)
    assert_equal ["welding_v2-kit/README.md", *BrandKitExport::FILES.keys.map { |name| "welding_v2-kit/#{name}" }], zipped.keys
    assert_equal files.readme, zipped.fetch("welding_v2-kit/README.md")
    BrandKitExport::FILES.each_key { |name| assert_equal files.svg(name), zipped.fetch("welding_v2-kit/#{name}"), name }
    assert_equal "welding_v2-kit.zip", files.zip_filename
  end

  test "a logo the brand cannot draw is left out of the zip and named in the README" do
    kit = BrandKit.for("welding_v2")
    kit.save_choice(:navbar, { rule: "4", text: "homogeneous", colouring: "original" }, by: "alex@test.com")
    kit.update_column(:navbar_choice, { "rule" => 9, "text" => "homogeneous" })
    files = BrandKitExport.new(kit.reload, base_url: BASE)
    assert_equal %w[navbar-light.svg navbar-dark.svg navbar-watermark.svg], files.drawings[:refused].keys
    refute entries(files.zip).key?("welding_v2-kit/navbar-dark.svg")
    assert_match(/\| navbar-dark\.svg \| not drawn \| .*rule/, files.readme)
  end
end
