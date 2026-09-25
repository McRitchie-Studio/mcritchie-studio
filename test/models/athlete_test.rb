require "test_helper"

class AthleteTest < ActiveSupport::TestCase
  test "slug is generated from person_slug" do
    person = Person.create!(first_name: "Test", last_name: "Player", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", position: "QB")
    assert_equal "test-player-athlete", athlete.slug
  end

  test "to_param returns slug" do
    athlete = athletes(:messi_athlete)
    assert_equal "lionel-messi-athlete", athlete.to_param
  end

  test "belongs to person via slug" do
    athlete = athletes(:messi_athlete)
    assert_equal people(:messi), athlete.person
  end

  test "person_slug is required" do
    athlete = Athlete.new(person_slug: nil, sport: "football")
    assert_not athlete.valid?
    assert_includes athlete.errors[:person_slug], "can't be blank"
  end

  test "sport is required" do
    athlete = Athlete.new(person_slug: "lionel-messi", sport: nil)
    assert_not athlete.valid?
    assert_includes athlete.errors[:sport], "can't be blank"
  end

  test "person_slug is unique" do
    assert_raises ActiveRecord::RecordInvalid do
      Athlete.create!(person_slug: "lionel-messi", sport: "soccer")
    end
  end

  test "person has_one athlete_profile" do
    person = people(:messi)
    assert_equal athletes(:messi_athlete), person.athlete_profile
  end

  test "draft fields are optional" do
    person = Person.create!(first_name: "No", last_name: "Draft", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "soccer", position: "MF")
    assert_nil athlete.draft_year
    assert_nil athlete.draft_round
    assert_nil athlete.draft_pick
  end

  test "team_slug is optional" do
    person = Person.create!(first_name: "Free", last_name: "Agent", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", position: "QB")
    assert_nil athlete.team_slug
    assert_nil athlete.team
  end

  test "belongs to team via team_slug" do
    person = Person.create!(first_name: "Team", last_name: "Player", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", position: "QB", team_slug: "buffalo-bills")
    assert_equal teams(:buffalo_bills), athlete.team
  end

  # --- the physical brief -------------------------------------------------
  #
  # These three fields were spelled out at TWO call sites with the same labels —
  # Appearance#generation_brief and Content::AssetsAgent#build_image_prompt — and
  # only one of them reached Higgsfield. One expression now serves both.

  test "the physical brief names each field that is filled in" do
    person = Person.create!(first_name: "Brief", last_name: "Subject", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football",
                              build: "6ft5 athletic", skin_tone: "light", hair_description: "long blond")

    brief = athlete.physical_brief

    assert_match "Build: 6ft5 athletic", brief
    assert_match "Skin tone: light", brief
    assert_match "Hair: long blond", brief
  end

  # Blank rather than "Build: . Skin tone: ." so a caller can compact it away
  # instead of testing each field itself.
  test "an athlete with no physical fields briefs as blank" do
    person = Person.create!(first_name: "Blank", last_name: "Subject", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")

    assert_predicate athlete.physical_brief, :blank?
  end

  test "a partly filled athlete names only what is known" do
    person = Person.create!(first_name: "Partial", last_name: "Subject", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", build: "6ft2 wiry")

    assert_equal "Build: 6ft2 wiry", athlete.physical_brief
  end
end
