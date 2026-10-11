require "test_helper"

# [unit] BODY ARCHETYPES: which one a look is drawn to. Synthetic people only.
class BodyArchetypeTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    @person = Person.create!(first_name: "Quill", last_name: "Arcwright")
  end

  def athlete!(position)
    Athlete.create!(person_slug: @person.slug, position: position, sport: "football")
  end

  test "a position defaults to the archetype whose hints name it" do
    assert_equal "nfl-qb-skill", BodyArchetype.default_for("QB").slug
    assert_equal "nfl-receiver-db", BodyArchetype.default_for("wr").slug
    assert_equal "nfl-lineman", BodyArchetype.default_for(" DT ").slug
  end

  test "an unknown or missing position falls back to the quarterback build" do
    assert_equal BodyArchetype::FALLBACK_SLUG, BodyArchetype.default_for(nil).slug
    assert_equal BodyArchetype::FALLBACK_SLUG, BodyArchetype.default_for("ZZ").slug
  end

  test "a look defaults by its athlete's position and the operator's pick outranks it" do
    athlete!("WR")
    look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home")

    assert_equal "nfl-receiver-db", look.body_archetype.slug
    assert_not look.body_archetype_chosen?

    look.update!(body_archetype_slug: "nfl-lineman")
    assert_equal "nfl-lineman", look.reload.body_archetype.slug
    assert look.body_archetype_chosen?
  end

  test "an iced twin is drawn to its base look's body" do
    athlete!("QB")
    look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home",
                              body_archetype_slug: "nfl-lineman")
    twin = Appearances::IcedTwin.create!(look)

    assert_equal "nfl-lineman", twin.reload.body_archetype.slug
  end

  test "an archetype is building only while its claim is fresh" do
    row = body_archetypes(:nfl_lineman)
    row.update!(generation_state: BodyArchetype::BUILDING, generation_started_at: 1.minute.ago)
    assert row.building?

    row.update!(generation_started_at: (BodyArchetype::STALE_AFTER + 1.minute).ago)
    assert_not row.building?
  end
end
