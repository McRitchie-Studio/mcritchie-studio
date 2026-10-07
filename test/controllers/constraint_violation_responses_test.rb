require "test_helper"

# [integration] A write the slug foreign keys refuse answers 422 with a reason a
# person can act on, never a 500.
class ConstraintViolationResponsesTest < ActionDispatch::IntegrationTest
  setup do
    @headers = {
      "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}"
    }
  end

  test "[integration] an API write naming a task that does not exist answers 422 with the reason" do
    assert_no_difference "TaskReviewClaim.count" do
      post review_claim_api_v1_task_path("no-such-task"), params: { session: "A", nonce: "a" }, headers: @headers, as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "CONSTRAINT_VIOLATION", body["error_code"]
    assert_equal %(Task slug names "no-such-task", which no task holds.), body["error"]
  end

  test "[unit] a delete that would strand children names the child table" do
    person = people(:josh_allen)
    error = assert_raises(ActiveRecord::InvalidForeignKey) { Person.where(id: person.id).delete_all }

    assert_match(/\AThis record is still in use by /, ConstraintViolationResponses.reason_for(error))
  end

  test "[unit] a unique-index refusal names the value" do
    error = assert_raises(ActiveRecord::RecordNotUnique) do
      Person.insert_all!([{ first_name: "Josh", last_name: "Allen", slug: "josh-allen", created_at: Time.current, updated_at: Time.current }])
    end

    assert_equal %(Slug "josh-allen" is already taken.), ConstraintViolationResponses.reason_for(error)
  end

  test "[integration] a web write naming a team that does not exist answers 422, not a 500" do
    log_in_as(users(:alex))

    patch news_path(news(:new_article).slug), params: { news: { primary_team_slug: "no-such-team" } }

    assert_response :unprocessable_entity
    assert_not_equal "no-such-team", news(:new_article).reload.primary_team_slug
  end
end
