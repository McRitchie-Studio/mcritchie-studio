require "test_helper"

module Api
  module V1
    # Integration coverage for the DevOps shift-lease endpoints.
    class DevopsShiftsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @headers = {
          "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}"
        }
      end

      def acquire(session:, nonce:, lane: "avi", label: nil)
        post acquire_api_v1_devops_shifts_path,
             params: { lane: lane, session: session, nonce: nonce, label: label },
             headers: @headers, as: :json
      end

      test "[integration] the first session acquires a free lane" do
        acquire(session: "A", nonce: "a", label: "Exeggcute")
        assert_response :ok
        body = response.parsed_body.fetch("data")
        assert body["acquired"]
        assert_equal "unclaimed", body["disposition"]
        assert_equal "Exeggcute", body.dig("holder", "label")
      end

      test "[integration] a careless second session is refused and sees the holder" do
        acquire(session: "A", nonce: "a", label: "Exeggcute")
        acquire(session: "B", nonce: "b")

        assert_response :ok
        body = response.parsed_body.fetch("data")
        refute body["acquired"], "the second Avi launch stands down"
        assert_equal "held_by_other", body["disposition"]
        assert_equal "Exeggcute", body.dig("holder", "label"), "the step-down message names the holder"
        assert body.dig("holder", "live")
      end

      test "[integration] only the holder can renew; a non-holder is a 204 no-op" do
        acquire(session: "A", nonce: "a")

        post renew_api_v1_devops_shifts_path, params: { lane: "avi", session: "A", nonce: "a" }, headers: @headers, as: :json
        assert_response :ok
        assert response.parsed_body.dig("data", "renewed")

        post renew_api_v1_devops_shifts_path, params: { lane: "avi", session: "B", nonce: "b" }, headers: @headers, as: :json
        assert_response :no_content
      end

      test "[integration] release frees the lane for the next session" do
        acquire(session: "A", nonce: "a")

        post release_api_v1_devops_shifts_path, params: { lane: "avi", session: "A", nonce: "a" }, headers: @headers, as: :json
        assert_response :ok

        acquire(session: "B", nonce: "b")
        assert response.parsed_body.dig("data", "acquired"), "a released lane is immediately acquirable"
      end

      test "[integration] a non-holder release is a 204 no-op and does not free the lane" do
        acquire(session: "A", nonce: "a")
        post release_api_v1_devops_shifts_path, params: { lane: "avi", session: "B", nonce: "b" }, headers: @headers, as: :json
        assert_response :no_content
        assert DevopsShift.find_by(lane: "avi").live?, "the lane is still held by A"
      end

      test "[integration] index lists each lane's holder" do
        acquire(session: "A", nonce: "a", lane: "avi", label: "Exeggcute")
        acquire(session: "B", nonce: "b", lane: "steffon", label: "Rotom")

        get api_v1_devops_shifts_path, headers: @headers
        assert_response :ok
        lanes = response.parsed_body.fetch("data")
        assert_equal %w[avi steffon], lanes.map { |l| l["lane"] }.sort
      end

      test "[integration] acquire requires auth" do
        acquire_headers = {}
        post acquire_api_v1_devops_shifts_path, params: { lane: "avi", session: "A", nonce: "a" }, headers: acquire_headers, as: :json
        assert_response :unauthorized
      end
    end
  end
end
