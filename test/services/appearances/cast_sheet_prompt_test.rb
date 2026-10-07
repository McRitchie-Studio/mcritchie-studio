require "test_helper"

# [unit] A character's sheet prompt is drawn, not photographed: it names the
# character, its look and personality, and carries NONE of the athlete
# prompt's person or likeness wording.
class Appearances::CastSheetPromptTest < ActiveSupport::TestCase
  setup do
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
    @character = Character.create!(name: "Turf Monster", kind: "mascot",
                                   personality: "[Draft for Alex] Loud and kind.")
    @look = @character.appearances.create!(descriptor: "Classic", colorway: "home green",
                                           generation_notes: "Green furry gator in a polo.")
  end

  test "names the character, the look, the notes and the personality, minus the draft marker" do
    prompt = Appearances::CastSheetPrompt.call(@look)

    assert_includes prompt, "Turf Monster, an original illustrated mascot"
    assert_includes prompt, "This look: Classic."
    assert_includes prompt, "Colourway: home green."
    assert_includes prompt, "Green furry gator in a polo."
    assert_includes prompt, "in keeping with this personality: Loud and kind:"
    assert_not_includes prompt, "[Draft"
    assert_includes prompt, "back view"
  end

  test "carries no person or likeness wording" do
    prompt = Appearances::CastSheetPrompt.call(@look)

    %w[man person photograph Photorealistic likeness facial jersey pads].each do |word|
      assert_no_match(/\b#{word}\b/i, prompt, "#{word.inspect} belongs to the athlete prompt")
    end
  end

  test "GenerateArtifact picks it for a character look and the athlete prompt for a person's" do
    assert_equal Appearances::CastSheetPrompt.call(@look), Appearances::GenerateArtifact.new(@look).prompt

    person_look = Appearance.create!(descriptor: "Bills home", person_slug: people(:josh_allen).slug)
    assert_includes Appearances::GenerateArtifact.new(person_look).prompt, "this exact man"
  end
end
