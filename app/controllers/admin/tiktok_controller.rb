module Admin
  # The one-time sign-in that connects a TikTok account to the hub. /connect
  # sends the admin to TikTok; /callback exchanges the code and stores the
  # connection itself (TiktokConnection: the open id, the granted scope, and
  # the refresh token encrypted). No token is rendered, flashed or logged, and
  # nobody copies one by hand.
  #
  # /disconnect deletes the stored connection.
  #
  # Neither action writes an ErrorLog row for an answer it expects: keys not
  # set, a bad TIKTOK_SCOPES, or a refusal from TikTok. Each gets plain words.
  class TiktokController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use auth code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "TikTok keys are not set on this server".freeze
    # Without the app's encryption keys the connection cannot be stored, and
    # TikTok's grant would be thrown away. So both actions refuse first.
    ENCRYPTION_NOT_SET = "This server cannot store a TikTok connection: its encryption keys are not set " \
                         "(#{TiktokConnection::ENCRYPTION_ENV.join(', ')}).".freeze
    ENCRYPTION_FIX = "Nothing was asked of TikTok. File the three keys on this server, then start again.".freeze

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
      return redirect_to(admin_dashboard_path, alert: "#{ENCRYPTION_NOT_SET} #{ENCRYPTION_FIX}") unless TiktokConnection.encryption_ready?

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
      # Before the exchange: a code is spent by it, and the grant could not be kept.
      return refuse(ENCRYPTION_NOT_SET, ENCRYPTION_FIX, status: :service_unavailable) unless TiktokConnection.encryption_ready?

      json = Tiktok::OAuthClient.exchange_code(code: params[:code], redirect_uri: callback_url)
      @connection  = TiktokConnection.store!(json, by: current_user.slug)
      @can_draft   = @connection.scopes.include?("video.upload")
      @direct_post = @connection.scopes.include?(Tiktok::OAuthClient::DIRECT_POST_SCOPE)
    rescue ActiveRecord::RecordInvalid => e
      # A validation message names the field that was missing, never its value.
      refuse("TikTok answered, but the connection was not saved.", "Start again: a code works once.",
             detail: e.record.errors.full_messages.to_sentence, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotUnique
      refuse("TikTok answered, but the connection was not saved.", "Another sign-in for this account was being saved. Start again.",
             status: :unprocessable_entity)
    rescue Tiktok::OAuthClient::NotConfigured
      refuse(KEYS_NOT_SET + ".", "File the client key and secret, then start again.")
    rescue Tiktok::OAuthClient::Error => e
      refuse("TikTok refused to exchange the sign-in code.", "Start again: a code works once and expires in minutes.", detail: e.message)
    end

    # Deletes every stored connection (the connected page's button, confirmed
    # there), then says what the server falls back to: with the env pair still
    # set, drafting carries on from it.
    def disconnect
      @deleted = TiktokConnection.delete_all
      @env_pair = Tiktok::OAuthClient.env_pair_present?
      render :disconnected
    end

    private

    def new_state
      SecureRandom.hex(16).tap { |state| session[:tiktok_oauth_state] = state }
    end

    # A refusal page: one plain sentence, the next step, and TikTok's own
    # words when there are any. ERB escapes every one of them.
    def refuse(sentence, fix, code: nil, detail: nil, status: :bad_request)
      @sentence = sentence
      @fix = fix
      @code = code
      @detail = detail
      @asked = asked_scopes
      @callback_url = callback_url
      render :refused, status:
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
