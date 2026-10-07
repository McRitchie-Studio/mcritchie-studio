require "test_helper"

# [integration] The person page's rename: admin only, the whole cascade on
# success, and a refusal rendered inline as a 422 with the reason.
class PeopleSlugRenameTest < ActionDispatch::IntegrationTest
  setup do
    @person = people(:josh_allen)
    log_in_as(users(:alex))
  end

  test "[integration] a rename redirects to the new address and the children follow" do
    get edit_slug_person_path(@person.slug)
    assert_response :success
    assert_select "[data-test=person-slug-form]"

    patch slug_person_path(@person.slug), params: { person: { slug: "joshua-allen" } }

    assert_redirected_to person_path("joshua-allen")
    assert_equal "joshua-allen", @person.reload.slug
    assert_equal "joshua-allen", Athlete.find_by!(slug: "josh-allen-athlete").person_slug
  end

  test "[integration] API and web rename with a duplicate slug answer 422 with the reason" do
    patch slug_person_path(@person.slug), params: { person: { slug: people(:james_cook).slug } }

    assert_response :unprocessable_entity
    assert_select "[data-test=person-slug-error]", text: /has already been taken/i
    assert_equal "josh-allen", @person.reload.slug
  end

  test "[integration] a badly formed slug is refused inline" do
    patch slug_person_path(@person.slug), params: { person: { slug: "Josh Allen" } }

    assert_response :unprocessable_entity
    assert_select "[data-test=person-slug-error]", text: /invalid/i
  end

  test "[integration] a non-admin cannot rename" do
    log_in_as(users(:viewer))

    patch slug_person_path(@person.slug), params: { person: { slug: "joshua-allen" } }

    assert_equal "josh-allen", @person.reload.slug
  end
end
