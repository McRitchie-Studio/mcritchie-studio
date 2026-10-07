require "test_helper"

# [unit] A look belongs to EXACTLY ONE of a Person or a Character, in the model
# and in the database (CHECK constraints on appearances and artifact_subjects),
# `owner` answers whichever is set, and a person-owned look behaves exactly as
# it did before characters existed.
class AppearanceOwnerTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    Character.delete_all
    @person = people(:josh_allen)
    @person.update_columns(default_appearance_slug: nil)
    @character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
  end

  # Each in its own savepoint, so the second violation is a real refusal and not
  # the aborted transaction the first one left behind.
  def assert_check_violation(&block)
    assert_raises(ActiveRecord::CheckViolation) { Appearance.transaction(requires_new: true, &block) }
  end

  test "the model refuses a look with no owner and a look with two" do
    none = Appearance.new(descriptor: "Classic")
    both = Appearance.new(descriptor: "Classic", person_slug: @person.slug, character_slug: @character.slug)

    assert_not none.valid?
    assert_not both.valid?
    assert_includes none.errors[:base], "A look belongs to exactly one person or one character"
    assert Appearance.new(descriptor: "Classic", person_slug: @person.slug).valid?
    assert Appearance.new(descriptor: "Classic", character_slug: @character.slug).valid?
  end

  test "the database refuses no owner and two owners, past the model" do
    look = Appearance.create!(descriptor: "Classic", character_slug: @character.slug)

    assert_check_violation { look.update_columns(character_slug: nil) }
    assert_check_violation { look.update_columns(person_slug: @person.slug) }
  end

  test "an artifact subject is exactly one owner too, in the model and the database" do
    artifact = Artifact.create!(kind: "character_sheet")
    assert_not ArtifactSubject.new(artifact_slug: artifact.slug).valid?
    row = ArtifactSubject.create!(artifact_slug: artifact.slug, character_slug: @character.slug)
    assert_equal @character, row.owner
    assert_equal "Turf Monster", row.display_name

    assert_check_violation { row.update_columns(person_slug: @person.slug) }
    assert_check_violation { row.update_columns(character_slug: nil) }
  end

  test "owner answers whichever is set, and owner_name names it" do
    mine = Appearance.create!(descriptor: "Classic", character_slug: @character.slug)
    theirs = Appearance.create!(descriptor: "Bills home", person_slug: @person.slug)

    assert_equal @character, mine.owner
    assert mine.character_owned?
    assert_equal "Turf Monster", mine.owner_name
    assert_equal @person, theirs.owner
    assert theirs.person_owned?
    assert_equal @person.full_name, theirs.owner_name
  end

  test "a character subject's effective look falls back to the character's default" do
    look = Appearance.create!(descriptor: "Classic", character_slug: @character.slug)
    artifact = Artifact.create!(kind: "character_sheet")
    row = ArtifactSubject.create!(artifact_slug: artifact.slug, character_slug: @character.slug)

    assert_equal look, row.effective_appearance
  end

  # PINS: a person's look still does what it did.
  test "a person's first look is their default, a destroy releases it, and the descriptor index is per owner" do
    first = Appearance.create!(descriptor: "Classic", person_slug: @person.slug)
    second = Appearance.create!(descriptor: "Away", person_slug: @person.slug)
    assert_equal first.slug, @person.reload.default_appearance_slug
    assert first.default?

    # The same descriptor is free for a character beside a person.
    assert Appearance.create!(descriptor: "Classic", character_slug: @character.slug).persisted?
    assert_raises(ActiveRecord::RecordNotUnique) do
      Appearance.transaction(requires_new: true) do
        Appearance.new(slug: "look-dupe", descriptor: "Classic", person_slug: @person.slug).save!(validate: false)
      end
    end

    first.destroy!
    assert_equal second.slug, @person.reload.default_appearance_slug
  end

  test "file_for_colorway! still files a person's look, idempotently" do
    look = Appearance.file_for_colorway!(person_slug: @person.slug, colorway: "Bills Home")
    again = Appearance.file_for_colorway!(person_slug: @person.slug, colorway: "bills home")

    assert_equal look, again
    assert_equal @person.slug, look.person_slug
    assert_nil look.character_slug
  end

  test "an athlete's number and the generation brief still come off the person" do
    look = Appearance.create!(descriptor: "Bills home", person_slug: @person.slug)
    athlete = @person.athlete_profile
    assert_equal athlete&.jersey_number, look.jersey_number if athlete&.jersey_number.is_a?(Integer)

    character_look = Appearance.create!(descriptor: "Classic", character_slug: @character.slug,
                                        generation_notes: "green gator")
    assert_nil character_look.jersey_number
    assert_equal "Classic\ngreen gator", character_look.generation_brief
  end

  test "recastable and person_owned exclude character looks" do
    person_look = Appearance.create!(descriptor: "Bills home", person_slug: @person.slug)
    character_look = Appearance.create!(descriptor: "Classic", character_slug: @character.slug)

    assert_includes Appearance.recastable, person_look
    assert_not_includes Appearance.recastable, character_look
    assert_equal [person_look], Appearance.person_owned.to_a
    assert_equal [character_look], Appearance.character_owned.to_a
  end
end
