require "test_helper"

# [unit] Looks, defaults, and the reuse key.
#
# The simplification this encodes: every person gets a DEFAULT look the moment
# their first one is created, so the common path never names an appearance at
# all. A variant — Burrow in a suit rather than a jersey — is an explicit later
# choice, not something the pipeline has to reason about every time.
class AppearanceTest < ActiveSupport::TestCase
  setup do
    Artifact.delete_all
    Appearance.delete_all
    @burrow = Person.create!(first_name: "Joe", last_name: "Burrow", athlete: true)
    @chase  = Person.create!(first_name: "JaMarr", last_name: "Chase", athlete: true)
  end

  test "the first look created becomes the default" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_equal look.slug, @burrow.reload.default_appearance_slug
    assert look.default?
  end

  # Otherwise every lookup would have to special-case "has looks but no default".
  test "a second look does not steal the default" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    assert_equal first.slug, @burrow.reload.default_appearance_slug
    assert_not second.default?
  end

  test "the default can be moved deliberately" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    suit = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    suit.make_default!

    assert suit.reload.default?
    assert_equal suit.slug, @burrow.reload.default_appearance_slug
  end

  test "colorway is normalised so casing cannot fork an identity" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "  WHITE ")
    assert_equal "white", look.colorway
  end

  test "one live look per descriptor per person" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_raises ActiveRecord::RecordNotUnique do
      Appearance.new(slug: "dupe", person_slug: @burrow.slug, descriptor: "Bengals white").save!(validate: false)
    end
  end

  # An athlete's physical description comes free off the Athlete record; anyone
  # with no role record has only the notes, which is the whole reason the notes
  # live on the LOOK rather than on the person.
  test "the generation brief folds in athlete data when there is any" do
    Athlete.create!(person_slug: @burrow.slug, sport: "football", build: "6ft4 athletic", hair_description: "short brown")
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    brief = look.generation_brief
    assert_match "Bengals white", brief
    assert_match "6ft4 athletic", brief
    assert_match "short brown", brief
  end

  test "a person with no athlete record falls back to the look's notes" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    look = Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura",
                              generation_notes: "Hawaiian shirt, swept-up hair.")

    assert_match "Hawaiian shirt", look.generation_brief
  end
end
