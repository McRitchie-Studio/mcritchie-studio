require "test_helper"

module Api
  module V1
    # [integration] PATCH /api/v1/slugs/:kind/:slug renames a slug with every row
    # that names it, and a refusal answers 422 with the reason, never a 500.
    class SlugRenamesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
        @person = people(:josh_allen)
      end

      def bearer(session) = { "Authorization" => "Bearer #{session.token}" }
      def body = JSON.parse(response.body)

      def rename(kind, slug, slug_to, session: @admin)
        patch api_v1_slug_rename_path(kind: kind, slug: slug), params: { slug_to: slug_to }, headers: bearer(session), as: :json
      end

      test "[integration] a rename answers the new slug and moves every child row" do
        contract_count = Contract.where(person_slug: @person.slug).count
        assert contract_count.positive?, "fixture person holds contracts"

        rename("people", @person.slug, "joshua-allen")

        assert_response :success
        assert_equal "joshua-allen", body.dig("data", "slug")
        assert_equal "joshua-allen", @person.reload.slug
        assert_equal contract_count, Contract.where(person_slug: "joshua-allen").count
        assert_equal 0, Contract.where(person_slug: "josh-allen").count
      end

      test "[integration] API and web rename with a duplicate slug answer 422 with the reason" do
        taken = people(:james_cook).slug

        rename("people", @person.slug, taken)

        assert_response :unprocessable_entity
        assert_equal "SLUG_REFUSED", body["error_code"]
        assert_match(/has already been taken/i, body["error"])
        assert_equal "josh-allen", @person.reload.slug
      end

      test "[integration] a badly formed slug answers 422 with the reason" do
        rename("people", @person.slug, "Josh Allen!")

        assert_response :unprocessable_entity
        assert_match(/invalid/i, body["error"])
      end

      test "[integration] an unknown kind answers 422 and names the kinds" do
        rename("agents", "xan", "xander")

        assert_response :unprocessable_entity
        assert_equal "UNKNOWN_KIND", body["error_code"]
        assert_equal "xan", Agent.find_by!(slug: "xan").slug
      end

      test "[integration] a studio session cannot rename" do
        task = tasks(:new_task)
        task.update_columns(stage: "building")
        studio = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")

        rename("people", @person.slug, "joshua-allen", session: studio)

        assert_response :forbidden
        assert_equal "josh-allen", @person.reload.slug
      end
    end
  end
end
