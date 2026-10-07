require "test_helper"

# [unit] The Turf Monster seed is idempotent and never overwrites: one
# character, one Classic look set as default, the kit's two references filed
# once each, and an edited bio left alone on a re-run. No sheet is generated.
class Characters::SeedTurfMonsterTest < ActiveSupport::TestCase
  setup do
    AppearanceReferencePhoto.delete_all
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
    @stored = []
    @store = lambda do |bytes, type|
      @stored << type
      "https://assets.example.test/characters/turf-monster/refs/#{@stored.size}"
    end
  end

  def seed = Characters::SeedTurfMonster.call(store: @store)

  test "creates Turf Monster with a default Classic look and the kit references" do
    character = seed

    assert_equal %w[turf-monster Turf\ Monster mascot turf-monster],
                 [character.slug, character.name, character.kind, character.brand]
    assert character.bio.start_with?("[Draft for Alex]")
    look = character.default_appearance
    assert_equal "Classic", look.descriptor
    art = AppearanceReferencePhoto.where(appearance_slug: look.slug).gallery_order
    assert_equal 2, art.count
    assert art.all? { |p| p.chosen? && p.source == "upload" }
    assert_equal %w[image/webp image/jpeg], @stored
    assert_equal 0, Artifact.count, "the seed generates nothing"
  end

  test "a re-run adds nothing and keeps an edit" do
    seed.update!(bio: "Alex's words")
    again = seed

    assert_equal 1, Character.count
    assert_equal 1, again.appearances.count
    assert_equal 2, AppearanceReferencePhoto.count
    assert_equal 2, @stored.size, "nothing stored twice"
    assert_equal "Alex's words", again.reload.bio
  end

  test "the seeded look is ready for a sheet build: its anchor is the mascot art" do
    look = seed.default_appearance
    inputs = Content::ArtifactPlan::ModelInputs.new(look)

    assert_nil inputs.refusal_for(:sheet)
    assert_equal "https://assets.example.test/characters/turf-monster/refs/1", inputs.anchor.url
  end
end
