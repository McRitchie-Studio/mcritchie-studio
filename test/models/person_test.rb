require "test_helper"

class PersonTest < ActiveSupport::TestCase
  test "slug is generated from full name" do
    person = Person.create!(first_name: "Kylian", last_name: "Mbappe")
    assert_equal "kylian-mbappe", person.slug
  end

  test "to_param returns slug" do
    person = people(:messi)
    assert_equal "lionel-messi", person.to_param
  end

  test "full_name returns first and last name" do
    person = people(:messi)
    assert_equal "Lionel Messi", person.full_name
  end

  test "first_name is required" do
    person = Person.new(first_name: nil, last_name: "Test")
    assert_not person.valid?
    assert_includes person.errors[:first_name], "can't be blank"
  end

  test "last_name is required" do
    person = Person.new(first_name: "Test", last_name: nil)
    assert_not person.valid?
    assert_includes person.errors[:last_name], "can't be blank"
  end

  test "has many contracts" do
    person = people(:messi)
    assert_respond_to person, :contracts
  end

  test "has many teams through contracts" do
    person = people(:messi)
    assert_includes person.teams, teams(:argentina)
  end

  # --- find_by_name tests ---

  test "find_by_name finds exact slug match" do
    found = Person.find_by_name("Lionel", "Messi")
    assert_equal people(:messi), found
  end

  test "find_by_name finds normalized slug (strips periods)" do
    person = Person.create!(first_name: "JT", last_name: "Tuimoloau")
    found = Person.find_by_name("J.T.", "Tuimoloau")
    assert_equal person, found
  end

  test "find_by_name finds alias match" do
    person = people(:cam_ward)
    person.update!(aliases: ["Cam Ward", "Cameron Ward"])
    # The slug is cam-ward, so searching for Cameron Ward (slug: cameron-ward) won't match slug.
    # But it should match via alias.
    found = Person.find_by_name("Cameron", "Ward")
    assert_equal person, found
  end

  test "find_by_name returns nil when not found" do
    found = Person.find_by_name("Nonexistent", "Player")
    assert_nil found
  end

  # --- find_or_create_by_name! tests ---

  test "find_or_create_by_name! finds existing person" do
    existing = people(:messi)
    found = Person.find_or_create_by_name!("Lionel", "Messi", athlete: true)
    assert_equal existing, found
    assert_no_difference "Person.count" do
      Person.find_or_create_by_name!("Lionel", "Messi")
    end
  end

  test "find_or_create_by_name! creates new person when not found" do
    person = nil
    assert_difference "Person.count", 1 do
      person = Person.find_or_create_by_name!("Zach", "Newguy", athlete: true)
    end
    assert_equal "Zach", person.first_name
    assert_equal "Newguy", person.last_name
    assert person.athlete?
  end

  test "find_or_create_by_name! auto-adds alias when name differs" do
    person = Person.create!(first_name: "JT", last_name: "Tuimoloau")
    assert_empty person.aliases

    found = Person.find_or_create_by_name!("J.T.", "Tuimoloau")
    assert_equal person, found
    assert_includes found.reload.aliases, "J.T. Tuimoloau"
  end

  test "find_or_create_by_name! does not duplicate aliases" do
    person = Person.create!(first_name: "JT", last_name: "Tuimoloau", aliases: ["J.T. Tuimoloau"])
    Person.find_or_create_by_name!("J.T.", "Tuimoloau")
    assert_equal 1, person.reload.aliases.count { |a| a == "J.T. Tuimoloau" }
  end

  # --- vocations: many, one primary (synthetic people only) ---

  def vocational(**attrs) = Person.create!(first_name: "Test", last_name: "Vocation #{SecureRandom.hex(3)}", **attrs)

  test "a person holds many vocations, stored in the list's order, and one primary" do
    person = vocational(vocations: %w[entertainer athlete actor], primary_vocation: "entertainer")

    assert_equal %w[athlete actor entertainer], person.reload.vocations
    assert_equal "entertainer", person.primary_vocation
    assert person.vocation?(:actor)
    assert_not person.vocation?("coach")
  end

  test "the primary must be one of the person's vocations" do
    person = vocational(vocations: %w[athlete actor])

    person.primary_vocation = "musician"
    assert_not person.valid?
    assert_includes person.errors[:primary_vocation], "must be one of this person's vocations"

    person.primary_vocation = "actor"
    assert person.valid?
    assert_not Person.new(first_name: "Test", last_name: "Nobody", primary_vocation: "actor").valid?,
               "a primary with no vocations at all"
  end

  test "an unknown vocation is refused" do
    person = Person.new(first_name: "Test", last_name: "Astronaut", vocations: %w[athlete astronaut])

    assert_not person.valid?
    assert_match "has no astronaut", person.errors[:vocations].first
  end

  test "a blank primary is filled from the first vocation, and no vocations means no primary" do
    person = vocational(vocations: %w[musician actor])
    assert_equal "actor", person.primary_vocation

    person.update!(vocations: [])
    assert_nil person.reload.primary_vocation
  end

  test "taking away the primary's vocation moves the primary to one still held" do
    person = vocational(vocations: %w[athlete actor], primary_vocation: "athlete")

    person.update!(vocations: %w[actor entertainer])
    assert_equal "actor", person.reload.primary_vocation
  end

  test "the athlete and coach booleans and the list stay in step, whichever is written" do
    imported = vocational(athlete: true)
    assert_equal [%w[athlete], "athlete"], imported.values_at(:vocations, :primary_vocation)

    imported.update!(coach: true)
    assert_equal [%w[athlete coach], "athlete"], imported.reload.values_at(:vocations, :primary_vocation)

    imported.update!(athlete: false)
    assert_equal [%w[coach], "coach"], imported.reload.values_at(:vocations, :primary_vocation)

    edited = vocational(vocations: %w[coach entertainer], primary_vocation: "entertainer")
    assert_equal [false, true], edited.values_at(:athlete, :coach)
    edited.update!(vocations: %w[athlete entertainer])
    assert_equal [true, false], edited.reload.values_at(:athlete, :coach)
    assert_equal 1, Person.where(athlete: true, slug: [imported.slug, edited.slug]).count, "the SQL readers see the list"
  end

  test "find_or_create_by_name! with a flag gives a known person the vocation and keeps their primary" do
    person = vocational(vocations: %w[entertainer])

    Person.find_or_create_by_name!(person.first_name, person.last_name, athlete: true)
    assert_equal [%w[athlete entertainer], "entertainer", true], person.reload.values_at(:vocations, :primary_vocation, :athlete)
  end

  test "a person linked to an artist becomes a musician and keeps their primary" do
    person = vocational(athlete: true)
    artist = Artist.create!(slug: "test-vocation-artist", name: "Test Vocation Artist", kind: "person")
    assert_equal %w[athlete], person.reload.vocations

    artist.update!(person_slug: person.slug)
    assert_equal [%w[athlete musician], "athlete"], person.reload.values_at(:vocations, :primary_vocation)
  end
end
