require "test_helper"

# [integration] THE ARCHETYPE PAGE AND THE LOOK'S POINTER. Generating is one paid
# image, so the gate is the point; nothing here reaches a vendor (the job is only
# enqueued, never performed).
class BodyArchetypesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Appearance.delete_all
    @admin = users(:alex)
    @viewer = users(:viewer)
    @person = Person.create!(first_name: "Quill", last_name: "Arcwright")
    Athlete.create!(person_slug: @person.slug, sport: "football", position: "QB")
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home")
  end

  test "the page lists the three archetypes, imageless, each with a generate button" do
    log_in_as(@admin)
    get body_archetypes_path

    assert_response :success
    assert_select "[data-test=archetype]", 3
    assert_select "[data-test=archetype-no-image]", 3
    assert_select "[data-test=archetype-generate]", 3
  end

  test "a non-admin can neither read the page nor spend" do
    log_in_as(@viewer)
    get body_archetypes_path
    assert_response :redirect

    with_env("OPENAI_API_KEY", "sk-test") { post generate_body_archetype_path("nfl-lineman") }
    assert_no_enqueued_jobs only: BodyArchetypeGenerateJob
    assert_nil body_archetypes(:nfl_lineman).reload.generation_state
  end

  test "an admin's press enqueues exactly one generation" do
    log_in_as(@admin)

    with_env("OPENAI_API_KEY", "sk-test") do
      assert_enqueued_jobs 1, only: BodyArchetypeGenerateJob do
        post generate_body_archetype_path("nfl-lineman")
      end
    end
    assert_redirected_to body_archetypes_path
    assert_equal BodyArchetype::BUILDING, body_archetypes(:nfl_lineman).reload.generation_state
  end

  test "the look page shows the position default and the operator can change it" do
    log_in_as(@admin)
    look_path = person_appearance_path(@person.slug, @look.slug)

    get look_path
    assert_select "[data-test=archetype-current][data-slug='nfl-qb-skill']"
    assert_select "[data-test=archetype-current]", /default for QB/

    patch archetype_person_appearance_path(@person.slug, @look.slug), params: { body_archetype_slug: "nfl-lineman" }
    assert_redirected_to look_path
    assert_equal "nfl-lineman", @look.reload.body_archetype_slug

    patch archetype_person_appearance_path(@person.slug, @look.slug), params: { body_archetype_slug: "" }
    assert_nil @look.reload.body_archetype_slug, "blank returns the look to its position default"
  end

  test "an unknown archetype is refused and nothing changes" do
    log_in_as(@admin)
    patch archetype_person_appearance_path(@person.slug, @look.slug), params: { body_archetype_slug: "nope" }

    assert_nil @look.reload.body_archetype_slug
    assert_match(/No body archetype/, flash[:alert])
  end
end
