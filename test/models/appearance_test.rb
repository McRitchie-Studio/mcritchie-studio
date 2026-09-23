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

  # --- the look an attach files ------------------------------------------
  #
  # An attach used to file `nil` whenever the content named a colorway the
  # person had no look in, which put the row under "no look" while every read
  # resolves nil to the person's DEFAULT. The row could then never be found by
  # the lookup that created it.

  test "a colorway with no look on file gets one filed for it" do
    assert_nil @burrow.appearances.live.find_by(colorway: "primary"),
               "the control — Burrow must have no primary look, or this proves nothing"

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal "primary", look.colorway
    assert_equal "Primary", look.descriptor
    assert_equal [look.slug], @burrow.appearances.live.pluck(:slug)
  end

  # Every upload runs this. Filing a second look per attach would turn the model
  # library into a pile.
  test "filing the same colorway twice returns the look already on file" do
    first  = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")
    second = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal first.slug, second.slug
    assert_equal 1, @burrow.appearances.count
  end

  test "an operator's own look in that colorway is used rather than a new one" do
    mine = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")

    assert_equal mine.slug, Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "  BLACK ").slug
    assert_equal 1, @burrow.appearances.count
  end

  # Nothing names a colorway, so there is nothing to file. nil then means "no
  # look was named AND the person has none" — the one state in which the read's
  # nil fallback agrees with the row.
  test "no colorway named files nothing" do
    assert_nil Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: nil)
    assert_nil Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "   ")
    assert_equal 0, Appearance.count
  end

  # The live-descriptor index would otherwise raise RecordNotUnique mid-attach
  # and fail the upload over a name collision.
  test "a descriptor already taken does not fail the filing" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Primary", colorway: "black")

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal "primary", look.colorway
    assert_equal "Primary 2", look.descriptor
    assert_equal 2, @burrow.appearances.live.count
  end

  # Retiring a look was a decision; filing reruns it rather than reviving it.
  test "a retired look in that colorway is not revived" do
    retired = Appearance.create!(person_slug: @burrow.slug, descriptor: "Primary", colorway: "primary")
    retired.update!(retired_at: Time.current)

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_not_equal retired.slug, look.slug
    assert_equal "Primary", look.descriptor, "the retired name is free again — the index only binds live looks"
  end
end
