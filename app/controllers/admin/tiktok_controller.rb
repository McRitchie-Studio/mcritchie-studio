module Admin
  # The one-time sign-in that connects a TikTok account to the hub. /connect
  # sends the admin to TikTok; /callback shows what came back, once: the
  # refresh token, the open id and the scope TikTok granted, for filing in
  # 1Password (item tiktok.studio.agents). The hub stores none of them itself.
  #
  # Neither action writes an ErrorLog row for an answer it expects: keys not
  # set, a bad TIKTOK_SCOPES, or a refusal from TikTok. Each gets plain words.
  class TiktokController < ApplicationController
    before_action :require_admin

    KEYS_NOT_SET = "TikTok keys are not set on this server".freeze

    # TikTok's `error` param on the callback => [what happened, what to do].
    # Anything else is shown in TikTok's own words (unknown_refusal).
    REFUSALS = {
      "scope" => [
        "The TikTok app lacks a permission this sign-in asked for.",
        "Add the missing product or scope to the app on developers.tiktok.com, or ask for less with TIKTOK_SCOPES."
      ],
      "redirect_uri" => [
        "This callback address is not registered on the TikTok app.",
        "Add it to the app's Login Kit redirect URIs, exactly as written below."
      ],
      "client_key" => [
        "TikTok does not accept this client key.",
        "The key and secret are a mismatched pair, or they belong to a production app TikTok has not approved."
      ],
      "non_sandbox_target" => [
        "The signed-in TikTok account is not a target user of the sandbox app.",
        "Add the account under the app's Sandbox settings, Target Users, or sign in as one already listed."
      ],
      "access_denied" => [
        "The sign-in was declined on TikTok.",
        "Nothing was connected. Start again when ready."
      ]
    }.freeze

    def connect
      url = Tiktok::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state)
      redirect_to url, allow_other_host: true
    rescue Tiktok::OAuthClient::NotConfigured
      redirect_to admin_dashboard_path, alert: KEYS_NOT_SET
    rescue Tiktok::OAuthClient::InvalidScopes => e
      redirect_to admin_dashboard_path, alert: e.message
    end

    def callback
      expected_state = session.delete(:tiktok_oauth_state)
      if params[:state].blank? || params[:state] != expected_state
        return render plain: "OAuth state mismatch — restart the connect flow.", status: :bad_request
      end
      return refuse_as_tiktok_said(params[:error].to_s) if params[:error].present?

      json = Tiktok::OAuthClient.exchange_code(code: params[:code], redirect_uri: callback_url)
      @refresh_token = json["refresh_token"]
      @open_id       = json["open_id"]
      @scope         = json["scope"].to_s
      granted        = @scope.split(",").map(&:strip)
      @can_draft     = granted.include?("video.upload")
      @direct_post   = granted.include?(Tiktok::OAuthClient::DIRECT_POST_SCOPE)
    rescue Tiktok::OAuthClient::NotConfigured
      refuse(KEYS_NOT_SET + ".", "File the client key and secret, then start again.")
    rescue Tiktok::OAuthClient::Error => e
      refuse("TikTok refused to exchange the sign-in code.", "Start again: a code works once and expires in minutes.", detail: e.message)
    end

    private

    def new_state
      SecureRandom.hex(16).tap { |state| session[:tiktok_oauth_state] = state }
    end

    # A refusal page: one plain sentence, the next step, and TikTok's own
    # words when there are any. ERB escapes every one of them.
    def refuse(sentence, fix, code: nil, detail: nil)
      @sentence = sentence
      @fix = fix
      @code = code
      @detail = detail
      @asked = asked_scopes
      @callback_url = callback_url
      render :refused, status: :bad_request
    end

    def refuse_as_tiktok_said(code)
      detail = params[:error_description].to_s.strip[0, 500].presence
      sentence, fix = REFUSALS.fetch(code) do
        ["TikTok refused the sign-in, in its own words:", "Fix what TikTok names on developers.tiktok.com, then start again."]
      end
      refuse(sentence, fix, code: code[0, 100], detail:)
    end

    def asked_scopes
      Tiktok::OAuthClient.requested_scopes.join(", ")
    rescue Tiktok::OAuthClient::InvalidScopes
      nil
    end

    def callback_url
      url_for(controller: "admin/tiktok", action: "callback", only_path: false)
    end
  end
end
