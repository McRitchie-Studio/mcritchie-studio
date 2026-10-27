# frozen_string_literal: true

require "test_helper"
require_relative "../support/marketing_kit_fixtures"

# [unit] MarketingKit renderers — the guidelines page, the Doc templates, the
# kit docs and the Office payloads say what the spec says, and Build lays every
# file into the standard folders. Chrome and Python are not run (pdf: false,
# office: false); their inputs are what is checked.
class MarketingKitRenderTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  test "the guidelines show every swatch, the tagline and the brand's words" do
    load_kit do |spec|
      html = MarketingKit::Guidelines.new(spec).html
      spec.palette.each { |s| assert_includes html, s[:hex].upcase }
      assert_includes html, "RGB 47, 107, 79"
      assert_includes html, "BUILT TO LAST"
      assert_includes html, spec.pitch
      assert_includes html, "Job of the month"
      assert_includes html, "repeat(6,1fr)", "the swatch grid has one column per swatch"
      assert_includes html, "file://#{spec.logo_png(:full, :dark)}"
      assert_equal 4, html.scan("<section class='page").size
    end
  end

  test "spec text is escaped, not injected" do
    load_kit(edit: ->(d) { d["voice"] = "Plain <script>alert(1)</script> & direct" }) do |spec|
      html = MarketingKit::Guidelines.new(spec).html
      assert_includes html, "Plain &lt;script&gt;alert(1)&lt;/script&gt; &amp; direct"
      refute_includes html, "<script>alert"
    end
  end

  test "the proposal carries the brand's terms only when the spec has them" do
    load_kit do |spec|
      html = MarketingKit::DocTemplates.new(spec).proposal
      refute_includes html, "TERMS OF SERVICE"
      refute_includes html, "Terms of Service that follow"
      assert_includes html, "ABOUT US"
      assert_includes html, "WHY CHOOSE US?"
      assert_includes html, "RF-YYYY-000"
      refute_includes html, "CLIENTS", "no clients page without clients"
    end
    terms = ->(d) { d["proposal"]["terms_of_service"] = { "intro" => ["These terms apply."], "items" => [["Payment", "Due on receipt."]] } }
    load_kit(edit: terms) do |spec|
      html = MarketingKit::DocTemplates.new(spec).proposal
      assert_includes html, "TERMS OF SERVICE"
      assert_includes html, "<b>Payment.</b> Due on receipt."
      assert_includes html, "Terms of Service that follow"
    end
  end

  test "the Doc templates embed their images and use the brand colours" do
    load_kit do |spec|
      general = MarketingKit::DocTemplates.new(spec).general
      assert_includes general, "data:image/png;base64,"
      assert_includes general, "data:image/jpeg;base64,"
      assert_includes general, "REQUEST A QUOTE"
      assert_includes general, "background-color:#C8702E"
    end
  end

  test "Start Here lists every standard folder and the Brand Guide the palette" do
    load_kit do |spec|
      docs = MarketingKit::KitDocs.new(spec)
      start = docs.start_here.html
      MarketingKit::Layout::PURPOSE.each_key { |folder| assert_includes start, folder }
      assert_includes start, "<code>RF_&lt;type&gt;_&lt;subject&gt;_&lt;variant&gt;</code>"
      assert_includes docs.brand_guide.html, "Ridge Green"
      assert_equal ["Messaging and Boilerplate"], docs.extras.map(&:title)
      assert_equal "03 Messaging", docs.extras.first.folder
    end
  end

  test "a doc listed in a folder outside the layout is refused" do
    load_kit(edit: ->(d) { d["docs"][0]["folder"] = "09 Misc" }) do |spec|
      assert_raises(MarketingKit::Error) { MarketingKit::KitDocs.new(spec).extras }
    end
  end

  test "the slides payload takes the spec's words and falls back to placeholders" do
    load_kit do |spec|
      payload = MarketingKit::Office.new(spec).slides_payload
      assert_equal "[Why Ridgeline]", payload[:points_title]
      assert_equal 3, payload[:points].size
      assert_equal "#2F6B4F", payload[:colours][:primary]
      assert_equal spec.photo_path("stair-install.jpg"), payload[:images][:half]
      assert_equal 4, payload[:timeline].size, "no timeline in the spec, so the placeholder one"
      assert_includes payload[:contact], "quotes@ridgeline.example"
    end
  end

  test "the tracker gets a Claims tab only when the spec lists claims" do
    load_kit do |spec|
      office = MarketingKit::Office.new(spec)
      assert_equal ["Asset Inventory", "Channels", "Backlog"], office.tracker_payload([]).fetch(:sheets).map { |s| s[:title] }
    end
    load_kit(edit: ->(d) { d["tracker"]["claims"] = [["25 years", "Home page", "Unproven", "Verify", "Open"]] }) do |spec|
      assert_equal "Claims to Review", MarketingKit::Office.new(spec).tracker_payload([]).fetch(:sheets).last[:title]
    end
  end

  test "Build lays every file into the standard folders and writes the manifest" do
    load_kit do |spec|
      Dir.mktmpdir do |out|
        build = MarketingKit::Build.new(spec, out: out, pdf: false, office: false).run
        by_folder = build.entries.group_by(&:folder).transform_values { |es| es.map(&:name) }

        assert_equal ["00 Start Here", "RF_logo_full_light.png", "RF_logo_full_dark.png", "RF_logo_horizontal_light.png",
                      "RF_logo_horizontal_dark.png", "RF_logo_icon_512.png", "RF_photo_shop-floor.jpg", "RF_photo_stair-install.jpg"],
                     by_folder[""]
        assert_equal ["Brand Guide"], by_folder["01 Brand"]
        assert_equal ["RF Template — General", "RF Template — Proposal"], by_folder["05 Templates"]
        assert_equal ["RF Kit Spec.yml", "messaging.html"], by_folder["01 Brand/Kit source"]
        assert_includes by_folder["01 Brand/Logos/SVG — print and web"], "RF_logo_horizontal_dark.svg"
        assert_equal 7, by_folder["01 Brand/Logos/PNG — Office and social"].size
        assert_equal 3, by_folder["02 Photography"].size

        manifest = JSON.parse(File.read(File.join(out, "manifest.json")))
        assert_equal build.entries.size, manifest.size
        assert manifest.all? { |e| File.file?(e["local"]) }, "every manifest entry points at a real file"
        assert File.file?(File.join(out, "guidelines", "guidelines.html"))
        inventory = JSON.parse(File.read(File.join(out, "Marketing Kit Tracker.xlsx.json")))["sheets"].first["rows"]
        assert_equal build.entries.size + 1, inventory.size, "every file plus the tracker itself"
      end
    end
  end
end
