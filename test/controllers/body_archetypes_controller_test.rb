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

  # [component] admin-url-columns-use-http-href: an archetype's stored image_url is
  # linked only as http(s). The refused value is a data: image, because image_tag
  # itself raises on a javascript: src (a separate, pre-existing 500).
  test "the page links an https archetype image and withholds a non-http one" do
    log_in_as(@admin)
    archetype = body_archetypes(:nfl_qb_skill)
    archetype.update_columns(image_url: "https://assets.example.test/qb.png")
    get body_archetypes_path
    assert_select "a[href='https://assets.example.test/qb.png'] img"

    archetype.update_columns(image_url: "data:image/svg+xml;base64,PHN2Zy8+")
    get body_archetypes_path
    assert_select "a[href^='data:']", 0
    assert_select "span[data-test='link-withheld'][title] img", 1
  end

  # [integration] image-tag-stored-url-500: image_tag reads a non-URL string as an
  # asset file name and the asset pipeline raises, so a javascript: image_url used to
  # answer 500. The page now answers 200 with the withheld placeholder and no image.
  test "a javascript: archetype image renders the withheld placeholder, not a 500" do
    log_in_as(@admin)
    archetype = body_archetypes(:nfl_qb_skill)
    archetype.update_columns(image_url: "javascript:alert(1)")
    get body_archetypes_path

    assert_response :success
    assert_select "[data-test=archetype][data-slug=?]", archetype.slug do
      assert_select "img", 0
      assert_select "a", { count: 0, text: /./ }
      assert_select "a[href^='javascript']", 0
      assert_select "[data-test='image-withheld'][title]", 1
    end

    archetype.update_columns(image_url: "https://assets.example.test/qb.png")
    get body_archetypes_path
    assert_select "img[src='https://assets.example.test/qb.png']", 1
    assert_select "[data-test='image-withheld']", 0
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

  test "a stalled generation and a reasonless failure each explain themselves" do
    log_in_as(@admin)
    body_archetypes(:nfl_lineman).update!(generation_state: BodyArchetype::BUILDING,
                                          generation_started_at: (BodyArchetype::STALE_AFTER + 10.minutes).ago)
    body_archetypes(:nfl_receiver_db).update!(generation_state: BodyArchetype::FAILED, generation_error: nil)

    get body_archetypes_path

    assert_select "[data-slug='nfl-lineman'] [data-test=archetype-stalled]", /never\s+finished/
    assert_select "[data-slug='nfl-lineman'] [data-test=archetype-generate]", 1, "a stalled run may be replaced"
    assert_select "[data-slug='nfl-receiver-db'] [data-test=archetype-failed]", /without a recorded reason/
    assert_select "[data-slug='nfl-receiver-db'] [data-test=archetype-failed] a[href='/error_logs']"
  end

  test "an archetype change that raises is logged against the look" do
    log_in_as(@admin)

    BodyArchetype.stub(:exists?, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        patch archetype_person_appearance_path(@person.slug, @look.slug), params: { body_archetype_slug: "nfl-lineman" }
      end
    end
    assert_match(/Could not change the body archetype/, flash[:alert])
    assert_equal @look.slug, ErrorLog.order(:id).last.target_name
  end
end
