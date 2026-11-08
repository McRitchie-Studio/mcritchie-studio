# frozen_string_literal: true

require "test_helper"

# [unit] BuildGallery: the apps /build and /websites list, and the portfolio
# card's shade (Alex McRitchie, 2026-11-06).
class BuildGalleryTest < ActiveSupport::TestCase
  # WCAG relative luminance contrast of two [r, g, b] colours (0-255).
  def contrast(a, b)
    lum = ->(rgb) { rgb.map { |c| v = c / 255.0; v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
                       .then { |r, g, bl| 0.2126 * r + 0.7152 * g + 0.0722 * bl } }
    hi, lo = [ lum.(a), lum.(b) ].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  def rgb(hex) = hex.delete("#").scan(/../).map { |pair| pair.to_i(16) }

  # The shade (the panel at alpha) laid over a backdrop.
  def shade_over(panel, backdrop)
    alpha = BuildGallery::PORTFOLIO_SHADE_ALPHA
    rgb(panel).zip(backdrop).map { |p, b| alpha * p + (1 - alpha) * b }
  end

  def showcase_live(subdomain, i)
    request = AppRequest.create!(prompt: "A showcase rebuild of #{subdomain}.").queue!("zz-gallery-#{i}")
    request.update_columns(subdomain: subdomain, status: "live", showcase: true)
  end

  test "Prisoner's Dilemma and Rantly are listed with a still and a loop, with no showcase request in the database" do
    assert_empty AppRequest.where(showcase: true, status: "live"), "control: no live showcase row feeds the gallery here"
    apps = BuildGallery.examples

    assert_operator apps.size, :>=, 4, "Cyvasse, Turf Monster and at least two more"
    assert_equal [ "Turf Monster", "Commercial Welding", "Cyvasse", "Prisoner's Dilemma", "Rantly" ], apps.first(5).map(&:name)
    { "Prisoner's Dilemma" => "prisoners-dilemma", "Rantly" => "rantly" }.each do |name, slug|
      app = apps.find { |example| example.name == name }
      assert_equal "build_gallery/#{slug}.webp", app.image, "#{name} has its dark still"
      assert_equal "build_gallery/#{slug}.mp4", app.motion, "#{name} has its hover loop"
      assert app.blurb.present?, "#{name} says what it is"
      catalog = AppCatalog.apps.find { |entry| entry.slug == slug }
      assert_equal catalog.production_url, app.url, "#{name} links to its AppCatalog production_url"
      assert_equal "showcase", catalog.status, "#{name} is Alex McRitchie's own showcase app, never a customer's"
    end
  end

  test "an app both listed and a live showcase request shows once, as listed" do
    showcase_live("rantly", 1)
    showcase_live("weekly-lock", 2)
    apps = BuildGallery.examples

    assert_equal 1, apps.count { |example| BuildGallery.subdomain(example.url) == "rantly" }
    assert_equal "Rantly", apps.find { |example| BuildGallery.subdomain(example.url) == "rantly" }.name
    assert_equal 1, apps.count { |example| BuildGallery.subdomain(example.url) == "weekly-lock" }, "an unlisted showcase app still joins"
    assert BuildGallery.showcased.any? { |example| example.url.include?("rantly") }, "control: the showcase copy exists before the drop"
  end

  test "every palette's name and text, and the Studio shade's, read at AA on the portfolio shade over pure white" do
    palettes = YAML.safe_load_file(BuildGallery::CONFIG).fetch("palettes").keys.map { |key| [ key, BuildGallery.palette_for(key) ] }
    palettes << [ "studio", BuildGallery::PORTFOLIO_SHADE ]
    assert_operator palettes.size, :>=, 9

    palettes.each do |name, palette|
      shade = shade_over(palette.fetch("panel"), [ 255, 255, 255 ])
      %w[name text].each do |key|
        ratio = contrast(rgb(palette.fetch(key)), shade)
        assert_operator ratio, :>=, 4.5, "#{name} #{key} #{palette[key]} on its shade over white is #{ratio.round(2)}:1"
      end
    end
  end

  test "the measure is not vacuous: Cyvasse's gold fails on a lighter shade" do
    cyvasse = BuildGallery.palette_for("cyvasse")
    light = rgb(cyvasse.fetch("panel")).zip([ 255, 255, 255 ]).map { |p, b| 0.85 * p + 0.15 * b }

    assert_operator contrast(rgb(cyvasse.fetch("name")), light), :<, 4.5
  end

  # [component] Commercial Welding's new site joins the portfolio (Alex McRitchie,
  # 2026-11-07): a hand-kept entry on its own domain, after Rantly, with a still
  # and a loop that exist, and a palette the card can paint.
  test "[component] Commercial Welding is listed with a still, a loop and a palette" do
    welding = BuildGallery.examples.find { |example| example.name == "Commercial Welding" }

    assert welding, "Commercial Welding is in the portfolio"
    assert_equal "https://commercialwelding.llc", welding.url
    %w[image motion].each do |field|
      assert Rails.root.join("app/assets/images", welding.public_send(field)).exist?, "#{field} file exists"
    end
    assert_equal({ "panel" => "#0B1824", "primary" => "#2D5E8E", "name" => "#9AB2C9", "text" => "#A0A5AA" },
                 BuildGallery.palette_for("commercialwelding"))
    # Alex McRitchie's order: Turf Monster, Commercial Welding, Cyvasse, then the rest.
    assert_equal [ "Turf Monster", "Commercial Welding", "Cyvasse" ], BuildGallery.examples.first(3).map(&:name)
  end
end
