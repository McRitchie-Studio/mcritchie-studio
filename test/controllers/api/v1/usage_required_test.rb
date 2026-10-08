require "test_helper"

module Api
  module V1
    # Guard catalog row 10.6. One rule (EventUsage) and one refusal
    # (Api::RequiresEventUsage) stand behind the three event endpoints and
    # ReleaseEvent's own validation.
    class UsageRequiredTest < ActionDispatch::IntegrationTest
      FIELDS = "model, tokens_in, tokens_out, cost".freeze
      USAGE = { model: "claude-test", tokens_in: 10, tokens_out: 5, cost: "0.01" }.freeze

      setup do
        @task = Task.create!(title: "usage rule task", stage: "submitted")
        @release = Release.open!
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)}"
        }
      end

      # Each endpoint's completing post, with `extra` merged into the event.
      def posts(extra = {})
        {
          "release" => ["/api/v1/releases/#{@release.slug}/events/ship_gate/complete",
                        { event: { actor: "avi", source: "agent" }.merge(extra) }],
          "task" => ["/api/v1/tasks/#{@task.slug}/events/smoke_check/complete",
                     { event: { actor: "xan", source: "agent" }.merge(extra) }],
          "review" => ["/api/v1/tasks/#{@task.slug}/review_events",
                       { review_event: { role: "light", moment: "completed", actor: "shannon",
                                         source: "agent" }.merge(extra) }]
        }
      end

      test "[integration] same refusal at the three endpoints" do
        bodies = nil
        assert_no_difference ["ReleaseEvent.count", "TaskEvent.count"] do
          bodies = posts.map do |name, (path, params)|
            post path, params: params, headers: @headers, as: :json
            assert_response :unprocessable_entity, "#{name}: a completion without usage is refused"
            response.parsed_body
          end
        end

        assert_equal [{ "error" => "event usage is required for agent completed events: #{FIELDS}",
                        "error_code" => "MISSING_EVENT_USAGE" }], bodies.uniq
      end

      test "[integration] the refusal names only the fields still missing" do
        posts(USAGE.except(:cost)).each do |name, (path, params)|
          post path, params: params, headers: @headers, as: :json
          assert_response :unprocessable_entity, name
          assert_equal "event usage is required for agent completed events: cost", response.parsed_body["error"], name
        end
      end

      # The control: the same posts with usage are recorded, so the refusal above is
      # the usage rule and not the route or the payload.
      test "[integration] the same posts with usage are recorded" do
        posts(USAGE).each do |name, (path, params)|
          post path, params: params, headers: @headers, as: :json
          assert_response :created, "#{name}: #{response.body}"
        end
      end

      test "[integration] an operator source owes no usage" do
        posts(source: "web").each do |name, (path, params)|
          post path, params: params, headers: @headers, as: :json
          assert_response :created, "#{name}: #{response.body}"
        end
      end

      test "[unit] the rule covers agent sources at completed and failed only" do
        blank = {}
        assert_equal EventUsage::FIELDS, EventUsage.missing(source: "cli", status: "failed", values: blank)
        assert_empty EventUsage.missing(source: "api", status: "started", values: blank)
        assert_empty EventUsage.missing(source: "web", status: "completed", values: blank)
        assert_empty EventUsage.missing(source: "agent", status: "completed",
                                        values: { model: "m", tokens_in: 0, tokens_out: 0, cost: 0 })
      end

      test "[unit] ReleaseEvent refuses the same events the endpoints refuse" do
        event = @release.release_events.build(step: "ship_gate", status: "failed", source: "cli", actor: "avi")

        assert_not event.valid?
        assert_equal EventUsage::FIELDS, event.errors.attribute_names & EventUsage::FIELDS
      end
    end
  end
end
