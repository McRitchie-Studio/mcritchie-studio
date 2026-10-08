require "test_helper"

# [unit] A look may not name a team that is not on file. `belongs_to :team` is
# optional and keyed by slug, so a slug with no row reads everywhere as "no
# team": production's first TikTok draft (2026-10-08) was refused that way
# while its look named a team. Checked on create and when the slug changes
# only, so a row that already carries a dangling slug still saves. Synthetic
# people; "test-comets" is a team that is in no fixture.
class AppearanceTeamTest < ActiveSupport::TestCase
  MISSING = "test-comets".freeze
  MESSAGE = "The look names team test-comets, which is not in the teams table".freeze

  setup { @person = Person.create!(athlete: true, first_name: "Test", last_name: "Team Look Alpha") }

  def look!(**attrs) = Appearance.create!(person_slug: @person.slug, descriptor: "Home", **attrs)

  test "a new look that names a team with no row is refused, in words that name the slug" do
    look = Appearance.new(person_slug: @person.slug, descriptor: "Home", team_slug: MISSING)

    assert_not look.valid?
    assert_equal [MESSAGE], look.errors.full_messages
    assert look.team_missing?
  end

  test "a look that names a team on file, or no team, saves" do
    assert_equal "buffalo-bills", look!(team_slug: "buffalo-bills").team.slug
    assert_nil Appearance.create!(person_slug: @person.slug, descriptor: "Suit", team_slug: nil).team
    assert Appearance.create!(person_slug: @person.slug, descriptor: "Blank", team_slug: "").valid?
  end

  test "changing a look's team to one with no row is refused" do
    look = look!(team_slug: "buffalo-bills")

    assert_not look.update(team_slug: MISSING)
    assert_equal [MESSAGE], look.errors.full_messages
    assert_equal "buffalo-bills", look.reload.team_slug
  end

  test "a row that already carries a dangling slug still saves for an unrelated edit, and can be corrected" do
    look = look!(team_slug: "buffalo-bills")
    look.update_column(:team_slug, MISSING) # as production's rows stood
    look.reload

    assert look.team_missing?
    assert look.update(jersey_number: 12), look.errors.full_messages.to_sentence
    assert_equal [MISSING, 12], look.reload.values_at(:team_slug, :jersey_number)
    assert look.update(team_slug: "miami-dolphins")
    assert_not look.team_missing?
  end

  test "the iced twin of a look whose team row is missing is refused with the same words, and nothing is made" do
    base = look!(team_slug: "buffalo-bills")
    base.update_column(:team_slug, MISSING)

    assert_equal "the look names team test-comets, which is not in the teams table", Appearances::IcedTwin.refusal(base.reload)
    assert_no_difference -> { Appearance.count } do
      assert_raises(Appearances::IcedTwin::Refused) { Appearances::IcedTwin.create!(base) }
    end
  end

  test "the iced twin of a look with a team on file carries that team" do
    assert_equal "buffalo-bills", Appearances::IcedTwin.create!(look!(team_slug: "buffalo-bills")).team_slug
  end
end
