require "test_helper"

module Api
  module V1
    # [integration] GET /api/v1/insights — the learning loop's feed-forward read
    # path. Serves the curated Insight Bank (ActionGrade.banked) as a capped,
    # newest-first list for the SessionStart injection hook. Bearer-gated.
    class InsightsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      def banked(slug:, **overrides)
        a = AgentAction.capture(session_id: "insight-#{slug.object_id}", kind: "edit", outcome: "ok",
                                 task_slug: overrides.delete(:task_slug))
        g = ActionGrade.create!({ agent_action: a, grader: "alex", slug: slug,
                                  disposition: "good" }.merge(overrides))
        g.bank!
        g
      end

      test "[integration] returns the banked insights newest-first with a count meta" do
        older = banked(slug: "older curated lesson here")
        older.update!(updated_at: 3.days.ago)
        banked(slug: "fresher curated lesson here")

        get api_v1_insights_path, headers: @headers

        assert_response :ok
        body = response.parsed_body
        assert_equal 2, body.dig("meta", "count")
        assert_equal "fresher curated lesson here", body["data"].first["slug"]
        assert_equal "older curated lesson here", body["data"].last["slug"]
      end

      test "[integration] each insight carries the compact feed shape" do
        banked(slug: "flag the gap first", disposition: "not", long_form: "Anchor: check siblings.",
               task_slug: "some-task-slug")

        get api_v1_insights_path, headers: @headers

        insight = response.parsed_body["data"].first
        assert_equal "flag the gap first", insight["slug"]
        assert_equal "not", insight["disposition"]
        assert_equal "Anchor: check siblings.", insight["long_form"]
        assert_equal "alex", insight["grader"]
        assert_equal "some-task-slug", insight["task_slug"]
      end

      test "[integration] honors the limit param (capped by the model)" do
        3.times { |i| banked(slug: "curated lesson number #{i} ok") }

        get api_v1_insights_path(limit: 1), headers: @headers

        assert_response :ok
        assert_equal 1, response.parsed_body["data"].size
      end

      test "[integration] an empty bank returns an empty feed, not an error" do
        get api_v1_insights_path, headers: @headers

        assert_response :ok
        assert_equal [], response.parsed_body["data"]
        assert_equal 0, response.parsed_body.dig("meta", "count")
      end

      test "[integration] requires auth — 401 without a token" do
        get api_v1_insights_path

        assert_response :unauthorized
      end
    end
  end
end
