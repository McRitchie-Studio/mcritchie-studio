module Admin
  # The hub's Fathom connection (the `sign_in` method of config/integrations.yml,
  # dogfooded here before clients get it): one Fathom sign-in, one ability,
  # reading meeting notes and transcripts. Its first use is a knowledge sweep
  # of Alex's own conversations.
  #
  # /admin/fathom (show) is the standing page: is it connected and as whom, and
  # a live read proving it (the first page of meetings and whether there are
  # more, the newest meeting's title and date, its transcript's lines and
  # speakers, and its summary's length), with Fathom's error said plainly; and
  # one button, Connect or Disconnect. The OAuth app and encryption keys show
  # (by NAME, never a value) only while one is missing.
  #
  # /connect sends the admin to Fathom; /callback checks the OAuth state,
  # exchanges the code, stores the connection (the refresh token encrypted) and
  # comes back to where Connect was pressed. No token, and no part of one, is
  # rendered, flashed or logged here. Fathom has no revoke endpoint, so
  # /disconnect deletes the stored token and says so.
  #
  # WHERE IT COMES BACK. Connect and Disconnect sit on this page and on the
  # /integrations Fathom card. Each takes ?return_to=, honoured only when it is
  # exactly one of RETURN_PATHS (never an open redirect); Connect keeps it in
  # the session beside the OAuth state.
  class FathomController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "Fathom connections are not set up on this server: " \
                   "#{Fathom::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{FathomConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Fathom.".freeze
    # The only places Connect and Disconnect come back to. Exact paths, no prefix match.
    RETURN_PATHS = %w[/integrations /admin/fathom].freeze

    # What the standing page proves about a connection.
    Read = Struct.new(:page, :newest, :transcript, :summary, keyword_init: true)

    def show
      @configured = Fathom::OAuthClient.connectable?
      @encryption_ready = FathomConnection.encryption_ready?
      @callback_url = callback_url
      @unreadable = FathomConnection.all.reject(&:readable?).map(&:account)
      @connection = FathomConnection.readable
      @read, @error = live_read(@connection) if @connection
    end

    def connect
      back = safe_return_to(params[:return_to])
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless FathomConnection.encryption_ready?

      session[:fathom_connect_return_to] = back
      redirect_to Fathom::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state), allow_other_host: true
    rescue Fathom::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:fathom_connect_oauth_state).to_s
      back = safe_return_to(session.delete(:fathom_connect_return_to))
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless state_matches?(expected)

      return redirect_to(back, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless FathomConnection.encryption_ready?

      grant = Fathom::OAuthClient.exchange_code(code: params[:code].to_s, redirect_uri: callback_url)
      connection = FathomConnection.store!(grant, account: account_for(grant), by: current_user.slug)
      redirect_to back, notice: "Fathom connected for #{connection.account}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Fathom answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue Fathom::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    rescue Fathom::OAuthClient::Error => e
      redirect_to back, alert: "Fathom refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    # Deletes every stored Fathom connection. Fathom documents no revoke, so
    # the grant itself stays until it is removed in Fathom; the page says so.
    def disconnect
      back = safe_return_to(params[:return_to])
      deleted = FathomConnection.delete_all
      Rails.logger.info("[fathom_connect] disconnect by=#{current_user.slug} at=#{Time.current.utc.iso8601} deleted=#{deleted}")
      notice = if deleted.zero? then "Fathom was not connected, so nothing changed."
               else "Fathom disconnected: the stored token was deleted here. Fathom has no revoke for us to call, so remove McRitchie Studio's access in Fathom's settings to be sure."
               end
      redirect_to back, notice:, status: :see_other
    end

    private

    # Who signed in: the recorder's email on the first page of meetings, read
    # with the exchange's own access token (no refresh is spent). LABEL when
    # Fathom names nobody or the read fails; the connection stores either way.
    def account_for(grant)
      token = grant["access_token"].presence or return FathomConnection::LABEL
      Fathom::Reader.new(token:).meetings.meetings.filter_map(&:recorded_by).first || FathomConnection::LABEL
    rescue Fathom::OAuthClient::Error
      FathomConnection::LABEL
    end

    # The page's live read, or Fathom's error said plainly. One refresh, then
    # at most three reads: well under Fathom's 60 a minute.
    def live_read(connection)
      reader = Fathom::Reader.new(connection)
      page = reader.meetings
      newest = reader.newest(page)
      read = Read.new(page:, newest:, transcript: newest && reader.transcript(newest.recording_id), summary: newest && reader.summary(newest.recording_id))
      [ read, nil ]
    rescue Fathom::OAuthClient::Revoked
      [ nil, "Fathom no longer accepts this connection: it was revoked, expired or its token was spent. Disconnect, then connect again." ]
    rescue Fathom::OAuthClient::Error => e
      [ nil, e.message ]
    end

    def refusal(code)
      return "The sign-in was declined on Fathom. Nothing was connected." if code == "access_denied"

      "Fathom refused the sign-in (#{code[0, 100]}). Check the OAuth app's redirect URI, then start again."
    end

    # A return path only when it is exactly an allowed one; otherwise this page.
    def safe_return_to(value)
      RETURN_PATHS.include?(value) ? value : admin_fathom_path
    end

    def state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:fathom_connect_oauth_state] = state }
    end

    # The redirect registered on both Fathom OAuth apps: exactly this path.
    def callback_url = admin_fathom_callback_url
  end
end
