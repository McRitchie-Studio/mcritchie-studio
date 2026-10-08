module Api
  module V1
    class AuthController < BaseController
      skip_before_action :authenticate_api!

      def create
        secret = params[:secret]
        expected = Rails.application.credentials.agent_api_secret || ENV["AGENT_API_SECRET"]
        unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(secret.to_s, expected)
          return render json: { error: "Invalid secret" }, status: :unauthorized
        end
        # An exchange of the secret is a legacy use too, counted by its caller.
        LegacyAuthUse.record!(endpoint: LegacyAuthUse::EXCHANGE, caller: LegacyAuthUse.caller_for(request))
        token = message_verifier.generate(
          { authenticated: true, issued_at: Time.current.iso8601 },
          purpose: :api_auth, expires_in: 24.hours
        )
        render json: { token: token, expires_at: 24.hours.from_now.iso8601 }
      end
    end
  end
end
