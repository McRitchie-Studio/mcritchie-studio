require "test_helper"

# A form that fails validation re-renders with the shared error box, drawn in
# the danger tokens rather than the old dark-only red.
class FormErrorsRenderTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  test "[integration] an invalid task re-renders the form with the token error box" do
    assert_no_difference(-> { Task.count }) do
      post tasks_path, params: { task: { title: "" } }
    end

    assert_response :unprocessable_entity
    assert_select "[data-test=form-errors][role=alert]" do |boxes|
      classes = boxes.first["class"].split
      assert_includes classes, "text-danger-ink"
      assert_includes classes, "border-danger/40"
      assert_select "p", text: "Title can't be blank"
    end
    assert_no_match(/bg-red-900|text-red-300/, response.body)
  end

  test "[integration] an invalid news item re-renders the form with the token error box" do
    assert_no_difference(-> { News.count }) do
      post news_index_path, params: { news: { title: "" } }
    end

    assert_response :unprocessable_entity
    assert_select "[data-test=form-errors] p", text: "Title can't be blank"
  end
end
