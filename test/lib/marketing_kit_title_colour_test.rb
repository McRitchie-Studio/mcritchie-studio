# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../support/marketing_kit_fixtures"

# [unit] The optional `title` palette key: every renderer draws page, document
# and slide titles with it, bars and tables keep primary, and a spec without it
# renders byte for byte as it did before the key existed.
class MarketingKitTitleColourTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  TITLE = "#C8661F"
  PRIMARY = "#2F6B4F" # the worked example's primary
  WITH_TITLE = ->(d) { d["palette"] << { "key" => "title", "name" => "Forge Orange", "hex" => TITLE, "role" => "Titles" } }

  # SHA-256 of each render of the worked example (script/marketing_kit/kit.example.yml),
  # taken on the code before the title key existed. The temp kit folder is
  # normalised to KIT, the slides payload is hashed without its new :title entry,
  # and the Brand Guide's stacked-logo label (reworded in the same change) is
  # normalised to STACKED_LABEL. Start Here's heading is the kit folder's name,
  # renamed since (task brand-kits-share-and-template), so the old name is put
  # back before hashing. If a later change means to alter a render,
  # recompute these; this change must not.
  BEFORE = {
    guidelines: "5a7e168fb1aa419a5e4b5f79d8bfb70ecdd46f9ea9f20c91b6a3a9e691d01508",
    general: "f81b67db3f05d5a2392ec9f5d396cebea71b690691c133a6169a75235ee9b9ae",
    proposal: "a98d0b3e01162acb765a370d2ded11a1ef8556bef7fcb59f8f5566136665319f",
    start_here: "c1f5d3492a753b8536e1e123020b7971b9e3211ada73d63ff67e12be71d9b493",
    brand_guide: "52a96780cdc54b5644650d182fb2ef0a588158f29b399e2e8fdcdafa596d919b",
    slides: "4dd098e4b39323a0aa16f05459248ac807252d7de6f8d9daf564204d8f08e180"
  }.freeze

  test "the worked example, which sets no title, renders exactly as before" do
    load_kit do |spec|
      dir = File.dirname(spec.path)
      docs = MarketingKit::KitDocs.new(spec)
      templates = MarketingKit::DocTemplates.new(spec)
      payload = MarketingKit::Office.new(spec).slides_payload
      assert_equal PRIMARY, payload[:colours].delete(:title), "slides fall back to primary for titles"
      renders = {
        guidelines: MarketingKit::Guidelines.new(spec).html, general: templates.general, proposal: templates.proposal,
        start_here: docs.start_here.html.sub(">#{spec.root_name}<", ">Ridgeline Fabrication — Marketing Kit<"),
        brand_guide: docs.brand_guide.html.sub(">Stacked<", ">STACKED_LABEL<"),
        slides: JSON.generate(payload)
      }
      renders.each do |name, body|
        assert_equal BEFORE.fetch(name), Digest::SHA256.hexdigest(body.gsub(dir, "KIT")), "#{name} changed"
      end
    end
  end

  test "the guidelines draw page titles, the heading sample and idea titles in title; bars stay primary" do
    load_kit(edit: WITH_TITLE) do |spec|
      html = MarketingKit::Guidelines.new(spec).html
      assert_includes html, "h2 { font-weight:800; color:#{TITLE};"
      assert_includes html, ".ideas b { color:#{TITLE};"
      assert_match(/class='big' style='font-weight:800;color:#{TITLE}'>Montserrat ExtraBold/, html)
      assert_includes html, "height:.12in; background:#{PRIMARY};", "the top bar keeps primary"
    end
  end

  test "the Doc templates set titles in title, and keep bands, tables and the accent button" do
    load_kit(edit: WITH_TITLE) do |spec|
      t = MarketingKit::DocTemplates.new(spec)
      general = t.general
      assert_includes general, "font-weight:700;color:#{TITLE};font-size:30pt" # Document Title
      assert_includes general, "color:#{TITLE};font-size:12pt;font-weight:700;letter-spacing:2px" # SECTION TITLE
      assert_includes general, "font-weight:700;color:#{TITLE};font-size:18pt" # item headings
      assert_includes general, "background-color:#C8702E", "the button stays accent"
      proposal = t.proposal
      assert_includes proposal, "font-weight:700;color:#{TITLE};font-size:40pt" # PROPOSAL
      assert_includes proposal, "color:#{TITLE};font-weight:700;letter-spacing:2px;font-size:10pt", "column titles"
      assert_includes proposal, "background-color:#{PRIMARY};padding:12pt 18pt", "section bands stay primary"
      refute_includes proposal, "background-color:#{TITLE}", "no bar or table takes the title colour"
    end
  end

  test "the kit's own docs set h1 and h2 in title and table heads in primary" do
    load_kit(edit: WITH_TITLE) do |spec|
      html = MarketingKit::KitDocs.new(spec).brand_guide.html
      assert_match(/<h1 style="[^"]*color:#{TITLE}/, html)
      assert_match(/<h2 style="[^"]*color:#{TITLE}/, html)
      assert_match(/<th style="[^"]*background-color:#{PRIMARY}/, html)
    end
  end

  test "the slides payload carries title, and the tracker header keeps primary" do
    load_kit(edit: WITH_TITLE) do |spec|
      office = MarketingKit::Office.new(spec)
      assert_equal TITLE, office.slides_payload[:colours][:title]
      assert_equal PRIMARY, office.slides_payload[:colours][:primary]
      assert_equal PRIMARY.delete("#"), office.tracker_payload([])[:header_fill]
    end
  end

  test "the slide script draws its titles with title" do
    py = File.read(MarketingKit::Office::SCRIPT)
    assert_includes py, 'TITLE = col.get("title", BLUE)'
    assert_includes py, "def title(s, t): text(s, Inches(.7), Inches(.85), Inches(11.9), Inches(1), t, size=36, bold=True, color=TITLE)"
    assert_includes py, '"[Slide title]", size=36, bold=True, color=TITLE)'
    assert_includes py, '"[Project name]", size=34, bold=True, color=TITLE)'
  end

  test "the Brand Guide names the stacked logo without claiming a tagline" do
    load_kit do |spec|
      html = MarketingKit::KitDocs.new(spec).brand_guide.html
      refute_includes html, "with tagline"
      assert_match(/>Stacked</, html)
    end
  end
end
