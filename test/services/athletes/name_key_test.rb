require "test_helper"

# THE GUARD AGAINST CREATING A SECOND ROW FOR ONE HUMAN.
#
# The measurement that put NameKey in the codebase, re-asserted here as the first
# test: Person.find_by_name cannot see across a punctuation difference, so "no exact
# match" is not "new player", and an acquire that trusted it would have created a
# duplicate punter.
class Athletes::NameKeyTest < ActiveSupport::TestCase
  NK = Athletes::NameKey

  test "the gap this exists to cover: find_by_name misses across punctuation" do
    person = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)

    # The control. If this ever starts finding him, the near-match guard is no longer
    # load-bearing for this case and this file should say so.
    assert_nil Person.find_by_name("AJ", "Cole"),
               "find_by_name is expected to miss the unpunctuated spelling"
    assert_equal person, Person.find_by_name("A.J.", "Cole")

    # And what NameKey does about it.
    assert_equal NK.for("A.J. Cole"), NK.for("AJ Cole")
    assert_equal [person], NK.near_matches("AJ Cole")
  end

  test "keys collapse punctuation, case and spacing" do
    assert_equal "ajcole", NK.for("A.J. Cole")
    assert_equal "ajcole", NK.for("AJ Cole")
    assert_equal "ajcole", NK.for("  aj   cole ")
    assert_equal "deandrehopkins", NK.for("DeAndre Hopkins")
  end

  test "keys collapse a generational suffix, which is where records split" do
    # ESPN carries the suffix inside lastName — measured: "Washington Jr.",
    # "Zuhn III" — and this repo already ships a merge task for the split it causes.
    assert_equal "mikewashington", NK.for("Mike Washington Jr.")
    assert_equal "treyzuhn", NK.for("Trey Zuhn III")
    assert_equal NK.for("Will Anderson"), NK.for("Will Anderson Jr.")
    assert_equal "willanderson", NK.for("Will Anderson Sr.")
  end

  test "a one-token name keeps its only token" do
    # The suffix stripper must never empty the name: "Jr" alone is all we were given.
    assert_equal "jr", NK.for("Jr")
    assert_equal "neymar", NK.for("Neymar")
  end

  test "an empty name yields an empty key and matches nobody" do
    assert_equal "", NK.for(nil)
    assert_equal "", NK.for("   ")
    assert_empty NK.near_matches(nil)
    assert_empty NK.near_matches("")
  end

  test "near_matches finds a differently punctuated person and not a different one" do
    cole = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)
    Person.create!(first_name: "Myles", last_name: "Cole", athlete: true)

    found = NK.near_matches("AJ Cole")
    assert_equal [cole], found, "same surname, different first name must not match"
  end

  test "near_matches finds a suffixed namesake, which is a refusal and not a merge" do
    # Deliberately ambiguous: these are sometimes one man and sometimes two, which is
    # exactly why the caller STOPS instead of choosing.
    senior = Person.create!(first_name: "Will", last_name: "Anderson", athlete: true)

    assert_equal [senior], NK.near_matches("Will Anderson Jr.")
  end

  test "near_matches narrows on the suffix-stripped surname" do
    person = Person.create!(first_name: "Mike", last_name: "Washington Jr.", athlete: true)

    # The SQL narrows on "washington", so a stored surname that itself carries the
    # suffix still has to be reachable from a plain one.
    assert_equal [person], NK.near_matches("Mike Washington")
    assert_equal "washington", NK.bare_last_name("Mike Washington Jr.")
  end

  test "near_matches returns nobody when nobody is close" do
    Person.create!(first_name: "Chris", last_name: "Myarick", athlete: true)

    assert_empty NK.near_matches("Patrick Gurd")
  end
end
