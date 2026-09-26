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

  # --- the headshot S3 key prefix -----------------------------------------
  #
  # [unit] This string was built at TWO call sites — Nflverse::SeedPlayers
  # #cache_headshot and the `nfl:upload_headshots` rake task — and the two
  # disagreed about the teamless athlete. SeedPlayers defaulted the folder; the
  # rake task treated a missing team as a reason to skip the athlete entirely,
  # and the rake task is the one operators run. One expression now serves both.

  test "the headshot key prefix files an athlete under their team" do
    person = Person.create!(first_name: "Rostered", last_name: "Player", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "buffalo-bills")

    assert_equal "headshots/nfl/buffalo-bills/#{person.slug}", athlete.headshot_key_prefix
  end

  # THE CASE THE RAKE TASK USED TO DROP ON THE FLOOR. The folder is cosmetic, so
  # a blank team_slug picks a default rather than costing the athlete an avatar.
  test "a teamless athlete still gets a key prefix" do
    person = Person.create!(first_name: "Teamless", last_name: "Player", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: nil)

    assert_equal "headshots/nfl/free-agents/#{person.slug}", athlete.headshot_key_prefix
  end

  # An empty string is not nil, and `||` alone would have let it through to build
  # "headshots/nfl//slug" — a valid S3 key with a doubled separator that no
  # browse of the bucket would ever group correctly.
  test "an empty team_slug falls back rather than emptying the folder" do
    person = Person.create!(first_name: "Blank", last_name: "Roster", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "")

    assert_equal "headshots/nfl/free-agents/#{person.slug}", athlete.headshot_key_prefix
    refute_includes athlete.headshot_key_prefix, "//"
  end

  # THE ONE THAT PINS THE AGREEMENT rather than restating one side of it. Asks
  # BOTH writers for the same athlete's key and compares them, so re-forking the
  # expression in either place reddens this test. An assertion on the literal
  # string in each file would pass happily while the two drifted apart, which is
  # exactly what happened.
  test "both headshot writers build the same key for the same athlete" do
    person = Person.create!(first_name: "Agreed", last_name: "Upon", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "miami-dolphins",
                              espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/1.png")

    seen = nil
    Studio::ImageCache.stub(:cache!, ->(key_prefix:, **) { seen = key_prefix; {} }) do
      # upload_headshots: false only gates the CALL SITE inside #call (and keeps
      # the constructor from demanding AWS_ACCESS_KEY_ID); #cache_headshot is
      # what we are asking, so we ask it directly.
      seeder = Nflverse::SeedPlayers.new(csv_body: "", upload_headshots: false)
      seeder.send(:cache_headshot, athlete)
    end

    assert_equal athlete.headshot_key_prefix, seen,
                 "Nflverse::SeedPlayers must key headshots exactly as Athlete does — two " \
                 "spellings of this string is the defect this method exists to prevent"
  end

  # The width list forked the same way: [100, 400] was literal in SeedPlayers and
  # a separate constant in the rake task, so adding a width would have reached
  # one writer and not the other.
  test "the seeder caches the widths the model declares" do
    person = Person.create!(first_name: "Width", last_name: "Check", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "buffalo-bills",
                              espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/2.png")

    seen = nil
    Studio::ImageCache.stub(:cache!, ->(widths:, **) { seen = widths; {} }) do
      # upload_headshots: false only gates the CALL SITE inside #call (and keeps
      # the constructor from demanding AWS_ACCESS_KEY_ID); #cache_headshot is
      # what we are asking, so we ask it directly.
      seeder = Nflverse::SeedPlayers.new(csv_body: "", upload_headshots: false)
      seeder.send(:cache_headshot, athlete)
    end

    assert_equal Athlete::HEADSHOT_WIDTHS, seen
  end
end
