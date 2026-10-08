module Admin
  # The sign-in that connects a TikTok account to the hub. /connect sends the
  # admin to TikTok; /callback exchanges the code and stores the connection
  # itself (TiktokConnection: the open id, and the refresh token encrypted).
  # No token is rendered, flashed or logged, and nobody copies one by hand.
  class TiktokController < ApplicationController
    before_action :require_admin

    def connect
      state = SecureRandom.hex(16)
      session[:tiktok_oauth_state] = state
      redirect_to(
        Tiktok::OAuthClient.authorize_url(
          redirect_uri: callback_url,
          state:        state
        ),
        allow_other_host: true
      )
    end

    def callback
      expected_state = session.delete(:tiktok_oauth_state)
      if params[:state].blank? || params[:state] != expected_state
        return render plain: "OAuth state mismatch — restart the connect flow.", status: :bad_request
      end
      if params[:error].present?
        return render plain: "TikTok denied authorization: #{params[:error]} #{params[:error_description]}", status: :bad_request
      end

      json = Tiktok::OAuthClient.exchange_code(code: params[:code], redirect_uri: callback_url)
      @connection = TiktokConnection.store!(json, by: current_user.slug)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      # A validation message names the field that was missing, never its value.
      reason = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : "another sign-in for this account was being saved"
      render plain: "TikTok answered, but the connection was not saved (#{reason}). Start the connect flow again.",
             status: :unprocessable_entity
    rescue StandardError => e
      render plain: "TikTok token exchange failed: #{e.message}", status: :bad_request
    end

    private

    def callback_url
      url_for(controller: "admin/tiktok", action: "callback", only_path: false)
    end
  end
end
