require "test_helper"

# [unit] Api::V1::BaseController#authenticate_api! refuses a verified api_auth
# token that carries no expiry, and passes a fresh one that does.
#
# The probe is GET /api/v1/agents/<unknown>: an authenticated request reaches the
# controller and answers 404, a refused one stops at the filter with 401. So the
# status alone says which side of the gate the token landed on.
module Api
  module V1
    class TokenExpiryRequiredTest < ActionDispatch::IntegrationTest
      PROBE = "no-such-agent-token-expiry-probe".freeze

      def verifier = Rails.application.message_verifier("api_auth")

      def probe(token)
        get api_v1_agent_path(PROBE), headers: { "Authorization" => "Bearer #{token}" }
      end

      test "a correctly signed token with no exp is refused" do
        probe(verifier.generate("test", purpose: :api_auth))

        assert_response :unauthorized
        assert_match(/no expiry/, JSON.parse(response.body)["error"])
      end

      # The control for the test above: the same payload and purpose, differing
      # ONLY in the expiry, gets through. A gate that refused everything would
      # pass the refusal test and fail this one.
      test "a fresh token with exp passes" do
        probe(verifier.generate("test", purpose: :api_auth, expires_in: 1.hour))

        assert_response :not_found
      end

      test "a token minted by POST /api/v1/auth carries exp and passes" do
        secret = "token-expiry-test-secret"
        with_env("AGENT_API_SECRET" => secret) do
          Rails.application.credentials.stub(:agent_api_secret, nil) do
            post api_v1_auth_path, params: { secret: secret }
          end
        end
        assert_response :success
        token = JSON.parse(response.body).fetch("token")

        assert BaseController.token_expiry(token), "the minted token should carry an exp"
        probe(token)
        assert_response :not_found
      end

      test "an expired token is still refused" do
        token = verifier.generate("test", purpose: :api_auth, expires_in: 1.minute)
        travel 2.minutes do
          probe(token)
        end

        assert_response :unauthorized
      end

      test "token_expiry reads exp only from a well-formed envelope" do
        assert BaseController.token_expiry(verifier.generate("x", purpose: :api_auth, expires_in: 1.hour))
        assert_nil BaseController.token_expiry(verifier.generate("x", purpose: :api_auth))
        assert_nil BaseController.token_expiry("not-base64!!--deadbeef")
        assert_nil BaseController.token_expiry("#{Base64.strict_encode64('{"_rails":"flat"}')}--deadbeef")
        assert_nil BaseController.token_expiry("")
      end

      private

      def with_env(vars)
        saved = vars.keys.to_h { |k| [k, ENV[k]] }
        vars.each { |k, v| ENV[k] = v }
        yield
      ensure
        saved.each { |k, v| ENV[k] = v }
      end
    end
  end
end
