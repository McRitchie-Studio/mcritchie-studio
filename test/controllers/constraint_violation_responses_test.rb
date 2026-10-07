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

  # A request that trips a unique index the model does not validate, through the
  # handler itself: the API answers 422, and an index other than a slug is logged.
  class UniqueProbeController < Api::V1::BaseController
    def create
      now = Time.current
      # A savepoint, so the refused insert leaves the test's transaction usable.
      ActiveRecord::Base.transaction(requires_new: true) do
        if params[:kind] == "slug"
          Person.insert_all!([{ first_name: "Josh", last_name: "Allen", slug: "josh-allen", created_at: now, updated_at: now }])
        else
          pair = Contract.first.attributes.except("id").merge("slug" => "unique-probe-contract")
          Contract.insert_all!([pair])
        end
      end
      head :ok
    end
  end

  def with_probe_route
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw { post "/__unique_probe", to: "constraint_violation_responses_test/unique_probe#create" }
    yield
  ensure
    Rails.application.reload_routes!
  end

  test "[integration] a unique refusal off the slug is a 422 and an ErrorLog row" do
    with_probe_route do
      assert_difference "ErrorLog.count", 1 do
        post "/__unique_probe", params: { kind: "pair" }, headers: @headers, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_equal "CONSTRAINT_VIOLATION", JSON.parse(response.body)["error_code"]
  end

  test "[integration] a taken slug is a 422 with no ErrorLog row" do
    with_probe_route do
      assert_no_difference "ErrorLog.count" do
        post "/__unique_probe", params: { kind: "slug" }, headers: @headers, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/already taken/, JSON.parse(response.body)["error"])
  end
end
