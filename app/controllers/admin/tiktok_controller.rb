module Admin
  # The hub's TikTok connection. /admin/tiktok (show) is the standing page: is
  # an account connected, as whom, with what scope, since when and by whom,
  # until when; can the stored row still be read; are the fallback env pair,
  # the app's keys and the encryption keys set (their NAMES, never a value);
  # and the two actions, Sign in and Disconnect.
  #
  # /connect sends the admin to TikTok; /callback exchanges the code and stores
  # the connection itself (TiktokConnection: the open id, the granted scope,
  # and the refresh token encrypted). No token, and no part of one, is
  # rendered, flashed or logged by any action here, and nobody copies one by
  # hand.
  #
  # /disconnect deletes the stored connection and comes back to the standing
  # page. WHO DISCONNECTED, AND WHEN, is one structured log line
  # ("[tiktok] disconnect by=<admin slug> at=<UTC> deleted=<rows> ..."): this
  # app has no table that audits admin acts (TaskEvent and ReleaseEvent audit
  # the board), and the row that could have carried it is the one deleted.
  #
  # No action writes an ErrorLog row for an answer it expects: keys not set, a
  # bad TIKTOK_SCOPES, or a refusal from TikTok. Each gets plain words.
  class TiktokController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use auth code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "TikTok keys are not set on this server".freeze
    # Without the app's encryption keys the connection cannot be stored, and
    # TikTok's grant would be thrown away. So both actions refuse first.
    ENCRYPTION_NOT_SET = "This server cannot store a TikTok connection: its encryption keys are not set " \
                         "(#{TiktokConnection::ENCRYPTION_ENV.join(', ')}).".freeze
    DISCONNECTED = "TikTok disconnected: the stored connection was deleted from this server.".freeze
    NOTHING_STORED = "No TikTok connection was stored on this server, so nothing was deleted.".freeze
    ENV_PAIR_STILL_SET = "Drafting is still on: TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID are set on this server, and it drafts " \
                         "from them. Remove both from the server's config to turn drafting off.".freeze
    ENV_PAIR_NOT_SET = "Drafting is off: TIKTOK_REFRESH_TOKEN and TIKTOK_OPEN_ID are not set on this server, so nothing " \
                       "connects it to TikTok until an admin signs in again.".freeze
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

    def show
      @connection = TiktokConnection.current
      @readable = @connection&.readable? || false
      @env_pair = Tiktok::OAuthClient.env_pair_present?
      @app_keys = Tiktok::OAuthClient.app_creds_present?
      @encryption_ready = TiktokConnection.encryption_ready?
      @stand_in = !Tiktok::OAuthClient.sign_in_stand_in.nil?
      # Where drafting gets its token from, as Tiktok::OAuthClient.token_source
      # decides it: a stored row that cannot be read is no source, and the env
      # pair does not stand in for it.
      @source = if @connection then @readable ? :stored : :unreadable
                elsif @env_pair then :env
                else :none
                end
      @can_draft = @source == :stored && @connection.scopes.include?("video.upload")
      @direct_post = @source == :stored && @connection.scopes.include?(Tiktok::OAuthClient::DIRECT_POST_SCOPE)
    end

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

    # Deletes every stored connection (the standing page's button, confirmed
    # there), records who did it, then says on that page what the server falls
    # back to: with the env pair still set, drafting carries on from it, and
    # that is said as a warning.
    def disconnect
      deleted = TiktokConnection.delete_all
      env_pair = Tiktok::OAuthClient.env_pair_present?
      Rails.logger.info("[tiktok] disconnect by=#{current_user.slug} at=#{Time.current.utc.iso8601} " \
                        "deleted=#{deleted} env_pair=#{env_pair ? 'set' : 'unset'}")
      said = deleted.zero? ? NOTHING_STORED : DISCONNECTED
      if env_pair
        redirect_to admin_tiktok_path, alert: "#{said} #{ENV_PAIR_STILL_SET}", status: :see_other
      else
        redirect_to admin_tiktok_path, notice: "#{said} #{ENV_PAIR_NOT_SET}", status: :see_other
      end
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
