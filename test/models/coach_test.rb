require "test_helper"

class CoachTest < ActiveSupport::TestCase
  test "slug is generated from person_slug and role" do
    coach = coaches(:bills_hc)
    coach.save!
    assert_equal "sean-mcdermott-buffalo-bills-head_coach", coach.slug
  end

  test "validates role inclusion" do
    coach = coaches(:bills_hc)
    coach.role = "waterboy"
    assert_not coach.valid?
    assert_includes coach.errors[:role], "is not included in the list"
  end

  test "validates sport inclusion" do
    coach = coaches(:bills_hc)
    coach.sport = "basketball"
    assert_not coach.valid?
    assert_includes coach.errors[:sport], "is not included in the list"
  end

  test "validates lean inclusion when present" do
    coach = coaches(:bills_hc)
    coach.lean = "special_teams"
    assert_not coach.valid?
    assert_includes coach.errors[:lean], "is not included in the list"
  end

  test "lean can be nil" do
    coach = coaches(:bills_hc)
    coach.lean = nil
    assert coach.valid?
  end

  test "validates uniqueness of person_slug scoped to team and role" do
    existing = coaches(:bills_hc)
    duplicate = Coach.new(
      person_slug: existing.person_slug,
      team_slug: existing.team_slug,
      role: existing.role,
      sport: "football"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:person_slug], "has already been taken"
  end

  test "belongs to person via slug" do
    coach = coaches(:bills_hc)
    assert_equal people(:sean_mcdermott), coach.person
  end

  test "belongs to team via slug" do
    coach = coaches(:bills_hc)
    assert_equal teams(:buffalo_bills), coach.team
  end

  test "person has_many coaches" do
    person = people(:sean_mcdermott)
    assert_includes person.coaches, coaches(:bills_hc)
  end

  test "team has_many coaches" do
    team = teams(:buffalo_bills)
    assert_includes team.coaches, coaches(:bills_hc)
  end

  test "ordered_for_admin sorts by team name, then role, then person name" do
    bills_hc = coaches(:bills_hc) # Buffalo Bills / head_coach
    miami_oc = Coach.create!(
      person_slug: people(:messi).slug,
      team_slug: teams(:miami_dolphins).slug,
      role: "offensive_coordinator",
      sport: "football"
    )
    miami_hc = Coach.create!(
      person_slug: people(:pulisic).slug,
      team_slug: teams(:miami_dolphins).slug,
      role: "head_coach",
      sport: "football"
    )

    ordered = Coach.ordered_for_admin.to_a

    # Buffalo Bills sorts before Miami Dolphins by team name.
    assert_operator ordered.index(bills_hc), :<, ordered.index(miami_hc)
    # Within Miami, head_coach sorts before offensive_coordinator by role rank.
    assert_operator ordered.index(miami_hc), :<, ordered.index(miami_oc)
  end
end
