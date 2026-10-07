# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] The brand kits load per brand, carry the repos' own theme tokens, and
# hold only McRitchie-owned marks that exist on disk.
class EmailImages::BrandKitTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    EmailImages::BrandKit.reload!
    EmailBrandReference.delete_all
  end

  test "the three brands load by key" do
    assert_equal %w[turf-monster mcritchie-studio mcritchie-industries], EmailImages::BrandKit.keys
    assert_equal "Turf Monster", EmailImages::BrandKit.find!("turf-monster").label
    assert_raises(EmailImages::BrandKit::UnknownKit) { EmailImages::BrandKit.find!("acme") }
  end

  # The palette is the repo's theme tokens, not memory: Industries is Forge
  # Orange on Shop Black, not "furnace orange on deep navy".
  test "each palette carries its repo's theme tokens" do
    turf = EmailImages::BrandKit.find!("turf-monster").palette
    assert_equal "#2E7D32", turf["primary"]
    assert_equal "#8E82FE", turf["accent"]

    studio = EmailImages::BrandKit.find!("mcritchie-studio").palette
    assert_equal "#8E82FE", studio["primary"]
    assert_equal Studio.theme_dark, studio["dark"]

    industries = EmailImages::BrandKit.find!("mcritchie-industries").palette
    assert_equal "#C8661F", industries["primary"]
    assert_equal "#141516", industries["dark"]
  end

  test "every reference is a file in this repo that the generator can read" do
    EmailImages::BrandKit.all.each do |kit|
      assert_predicate kit.base_references, :any?, "#{kit.key} gives the generator nothing to draw from"
      kit.base_references.each do |ref|
        assert ref.exists?, "#{kit.key}: #{ref.path} is missing"
        assert_match %r{\Adata:image/(png|jpeg|webp);base64,}, ref.data_uri
      end
    end
  end

  test "turf leads with the gator, studio with the chest, industries with its mark" do
    assert_equal ["public/agents/turf-monster.webp", "mascot"],
                 EmailImages::BrandKit.find!("turf-monster").references.first.to_h.values_at(:path, :role)
    assert_equal "public/favicon.png", EmailImages::BrandKit.find!("mcritchie-studio").references.first.path
    assert_equal "public/email_brand/mcritchie-industries-icon.png",
                 EmailImages::BrandKit.find!("mcritchie-industries").references.first.path
  end

  test "every kit forbids real people and team marks" do
    EmailImages::BrandKit.all.each do |kit|
      assert_includes kit.negative.downcase, "no real people", kit.key
    end
    assert_includes EmailImages::BrandKit.find!("turf-monster").negative.downcase, "crests"
  end

  test "the 2:1 preset is 1200x600 generated at the tool's 1536x1024" do
    preset = EmailImages::BrandKit.preset("header_2x1")
    assert_equal [1200, 600, "1536x1024"], [preset.width, preset.height, preset.generate_size]
  end

  test "the spend ceiling defaults to two candidates and four rounds" do
    assert_equal 2, EmailImages::BrandKit.candidates_per_round
    assert_equal 4, EmailImages::BrandKit.max_rounds
    assert_equal 300_000, EmailImages::BrandKit.max_bytes
  end

  # --- the merge: YAML references plus active uploads, in one place --------

  def turf = EmailImages::BrandKit.find!("turf-monster")

  test "the kit merges its YAML references with its active uploads, newest upload first" do
    older = brand_reference(label: "older", created_at: 2.days.ago)
    newer = brand_reference(label: "newer", role: "style", created_at: 1.day.ago)

    refs = turf.references
    assert_equal %w[yaml yaml upload upload], refs.map(&:origin)
    assert_equal ["turf-monster.webp", "turf-monster-style-anchor.jpg", "newer", "older"], refs.map(&:label)
    assert_equal [newer.image_url, older.image_url], refs.select(&:upload?).map(&:generator_input)
  end

  test "archived uploads and other kits' uploads are left out" do
    brand_reference(label: "archived").archive!
    brand_reference(label: "studio's", brand_kit: "mcritchie-studio", role: "logo")

    assert_equal %w[yaml yaml], turf.references.map(&:origin)
    assert_equal ["studio's"], EmailImages::BrandKit.find!("mcritchie-studio").uploaded_references.map(&:label)
  end

  test "an upload is shown and sent by its URL; a YAML reference by its public path and inline bytes" do
    brand_reference
    yaml, upload = turf.references.values_at(0, 2)

    assert_equal "/agents/turf-monster.webp", yaml.display_url
    assert yaml.generator_input.start_with?("data:image/webp;base64,")
    assert_equal upload.url, upload.display_url
    assert_raises(ArgumentError) { upload.data_uri }
  end

  # --- the generator's cut ----------------------------------------------------

  test "with no uploads a round sends the kit's YAML references, in file order" do
    assert_equal %w[mascot style], turf.generator_references.map(&:role)
  end

  test "the lead YAML reference always goes first, then one per uncovered role, then the rest" do
    brand_reference(label: "m1", created_at: 3.days.ago)
    m2 = brand_reference(label: "m2", created_at: 2.days.ago)
    brand_reference(label: "o1", role: "other", created_at: 1.day.ago)
    brand_reference(label: "p1", role: "product", created_at: 4.days.ago)

    labels = turf.generator_references(limit: 10).map(&:label)
    assert_equal ["turf-monster.webp", "turf-monster-style-anchor.jpg", "p1", "o1", "m2", "m1"], labels,
                 "lead; style (YAML), product, other one each; then mascots newest first"
    assert_equal ["turf-monster.webp", "turf-monster-style-anchor.jpg", "p1", "o1"],
                 turf.generator_references(limit: 4).map(&:label)
    assert_equal ["turf-monster.webp", "turf-monster-style-anchor.jpg"], turf.generator_references(limit: 2).map(&:label),
                 "a pile of mascot uploads never crowds out the style anchor"
    assert_equal ["turf-monster.webp"], turf.generator_references(limit: 1).map(&:label)
    m2.archive!
    assert_equal %w[p1 o1 m1], turf.generator_references(limit: 10).map(&:label).last(3), "archived is never sent"
  end

  test "the cut is deterministic: the same rows give the same list every time" do
    t = Time.zone.parse("2026-10-06 12:00")
    3.times { |i| brand_reference(label: "same-second #{i}", role: "logo", created_at: t) }

    first = turf.generator_references(limit: 4).map(&:label)
    5.times { assert_equal first, EmailImages::BrandKit.find!("turf-monster").generator_references(limit: 4).map(&:label) }
    assert_equal ["turf-monster.webp", "same-second 2", "turf-monster-style-anchor.jpg", "same-second 1"], first,
                 "logo ranks above style; same timestamp, so the higher id is the newer"
  end

  test "the limit follows the row's reference arity" do
    one = Struct.new(:reference_arity).new("one")
    many = Struct.new(:reference_arity).new("many")
    assert_equal 1, EmailImages::BrandKit.reference_limit(one)
    assert_equal 4, EmailImages::BrandKit.reference_limit(many)
    assert_equal 4, EmailImages::BrandKit.reference_limit(nil)
    assert_equal 4, EmailImages::BrandKit.reference_limit(ImageGeneration::Registry.find("openai_image_header"))
  end
end
