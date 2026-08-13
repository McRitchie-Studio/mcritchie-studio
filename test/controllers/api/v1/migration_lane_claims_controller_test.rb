require "test_helper"

module Api
  module V1
    # Integration coverage for the `backend_migration` lane endpoints — the HTTP
    # surface `bin/task migration-lane acquire|release|status` rides. The lane's
    # mutual exclusion is proved against real connections in
    # test/integration/migration_lane_exclusion_race_test.rb; this file proves the
    # endpoints carry identity in and the verdict out.
    class MigrationLaneClaimsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      def acquire(session:, nonce:, task_slug: nil, agent: nil, label: nil)
        post api_v1_migration_lane_acquire_path,
             params: { session: session, nonce: nonce, task_slug: task_slug, agent: agent, label: label },
             headers: @headers, as: :json
      end

      def release(session:, nonce:)
        post api_v1_migration_lane_release_path,
             params: { session: session, nonce: nonce }, headers: @headers, as: :json
      end

      test "[integration] the lane starts free" do
        get api_v1_migration_lane_path, headers: @headers

        assert_response :ok
        assert_nil response.parsed_body.dig("data", "holder"), "an untaken lane has no holder"
      end

      test "[integration] the first agent acquires the lane" do
        acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")

        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert body["acquired"]
        assert_equal "unclaimed", body["disposition"]
        assert_equal "add-widgets-table", body.dig("holder", "task_slug")
        assert body.dig("holder", "live")
      end

      # The refusal is a NORMAL 200 outcome the caller branches on, not an error —
      # bin/task turns it into exit 10 ("queue, don't retry-storm").
      test "[integration] a second agent is refused and told who holds the lane" do
        acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")
        acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table", agent: "jasper")

        assert_response :ok
        body = response.parsed_body.fetch("data")
        refute body["acquired"], "two agents must never both hold the migration lane"
        assert_equal "held_by_other", body["disposition"]
        assert_equal "carl", body.dig("holder", "agent"), "the refusal names whom to ask for an ETA"
        assert_equal "add-widgets-table", body.dig("holder", "task_slug")
      end

      test "[integration] status reports the live holder" do
        acquire(session: "A", nonce: "a", task_slug: "add-widgets-table", agent: "carl")

        get api_v1_migration_lane_path, headers: @headers

        assert_response :ok
        holder = response.parsed_body.dig("data", "holder")
        assert holder["live"]
        assert_equal "add-widgets-table", holder["task_slug"]
      end

      test "[integration] the holder releases and the lane frees for the next agent" do
        acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")
        release(session: "A", nonce: "a")

        assert_response :ok
        assert response.parsed_body.dig("data", "released")
        refute response.parsed_body.dig("data", "holder", "live"), "a released lane reads as free"

        acquire(session: "B", nonce: "b", task_slug: "add-gizmos-table")
        assert response.parsed_body.dig("data", "acquired"), "the next agent takes the freed lane"
      end

      test "[integration] a non-holder cannot release the lane" do
        acquire(session: "A", nonce: "a", task_slug: "add-widgets-table")
        release(session: "B", nonce: "b")

        assert_response :ok
        refute response.parsed_body.dig("data", "released")
        assert response.parsed_body.dig("data", "holder", "live"), "the holder keeps the lane"
      end

      # The SOP's belt-and-suspenders release fires on shipped/blocked/archived
      # whether or not the lane was ever taken.
      test "[integration] releasing a never-acquired lane is a harmless no-op" do
        release(session: "nobody", nonce: "none")

        assert_response :ok
        refute response.parsed_body.dig("data", "released")
      end

      test "[integration] the endpoints require a bearer token" do
        get api_v1_migration_lane_path
        assert_response :unauthorized

        post api_v1_migration_lane_acquire_path, params: { session: "A", nonce: "a" }, as: :json
        assert_response :unauthorized
      end
    end
  end
end
