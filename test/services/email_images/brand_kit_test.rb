# frozen_string_literal: true

require "test_helper"

# [unit] The brand kits load per brand, carry the repos' own theme tokens, and
# hold only McRitchie-owned marks that exist on disk.
class EmailImages::BrandKitTest < ActiveSupport::TestCase
  setup { EmailImages::BrandKit.reload! }

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
      assert_predicate kit.references, :any?, "#{kit.key} gives the generator nothing to draw from"
      kit.references.each do |ref|
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
end
