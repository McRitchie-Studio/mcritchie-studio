require "test_helper"

module Api
  module V1
    # [integration] A malformed config/agent_media.yml reaches the release-notes
    # API as a named refusal (MEDIA_CONFIG_INVALID) logged to ErrorLog, not a 500.
    class ReleaseNotesMediaConfigTest < ActionDispatch::IntegrationTest
      setup do
        @headers = { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
        Media::Config.reset!
      end

      teardown { Media::Config.reset! }

      test "[integration] a malformed agent_media.yml is a 422 MEDIA_CONFIG_INVALID, logged" do
        bad = Psych::SyntaxError.new("config/agent_media.yml", 3, 1, 0, "did not find expected key", "while parsing")
        Media::Config.stub(:load, ->(*) { raise bad }) do
          assert_difference -> { ErrorLog.count }, 1 do
            post api_v1_release_notes_path, params: { app: "mcritchie-studio", release: "v1", sha: "abcdef0",
                                                      task_slugs: [ tasks(:new_task).slug ] }, headers: @headers, as: :json
          end
        end
        assert_response :unprocessable_entity
        assert_equal "MEDIA_CONFIG_INVALID", response.parsed_body["error_code"]
      end
    end
  end
end
