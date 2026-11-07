module Admin
  # The hub's Egnyte connections (the `sign_in` method of config/integrations.yml):
  # one sign-in per Egnyte domain, one scope (Egnyte.filesystem), so a domain's
  # folders can be browsed and a file uploaded. Built dark: it does nothing
  # until EGNYTE_CLIENT_ID and EGNYTE_CLIENT_SECRET are set, and then only when
  # an admin connects a domain.
  #
  # /admin/egnyte (show) is the standing page: each connected domain, who
  # granted it and when, and a live read proving it (one page of a folder,
  # /Shared by default; ?egnyte_domain=&path= browses one domain's folder), with
  # Egnyte's error said plainly; Disconnect per domain; and a domain field with
  # Connect. The developer key and encryption keys show (by NAME, never a
  # value) only while one is missing.
  #
  # /connect (POST, the domain in the form) sends the admin to that domain's
  # Egnyte sign-in; /callback checks the OAuth state, exchanges the code on the
  # domain kept in the session (never one from the callback's query), stores
  # the connection (both tokens encrypted) and comes back to where Connect was
  # pressed. No token, and no part of one, is rendered, flashed or logged here;
  # a refused exchange, refresh or read is kept in the error log
  # (rescue_and_log) as well as said on the page. /disconnect revokes the
  # domain's tokens on Egnyte, then deletes the row, and says if the revoke
  # failed.
  #
  # WHERE IT COMES BACK. Connect and Disconnect sit on this page and on the
  # /integrations Egnyte card. Each takes return_to, honoured only when it is
  # exactly one of RETURN_PATHS (never an open redirect).
  class EgnyteController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "Egnyte connections are not set up on this server: " \
                   "#{Egnyte::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{EgnyteConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Egnyte.".freeze
    BAD_DOMAIN = "That is not an Egnyte domain. Enter the name before .egnyte.com, for example \"acme\" for acme.egnyte.com.".freeze
    # The only places Connect and Disconnect come back to. Exact paths, no prefix match.
    RETURN_PATHS = %w[/integrations /admin/egnyte].freeze

    # What the standing page proves about one connection: a folder page, or Egnyte's error.
    Read = Struct.new(:folder, :error, keyword_init: true)

    def show
      @configured = Egnyte::OAuthClient.connectable?
      @encryption_ready = EgnyteConnection.encryption_ready?
      @callback_url = callback_url
      @unreadable = EgnyteConnection.all.reject(&:readable?).map(&:domain)
      @connections = EgnyteConnection.readable
      @reads = @connections.to_h { |connection| [ connection.domain, live_read(connection, browse_path(connection)) ] }
    end

    def connect
      back = safe_return_to(params[:return_to])
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless EgnyteConnection.encryption_ready?

      domain = EgnyteConnection.normalize_domain(params[:egnyte_domain]) or return redirect_to(back, alert: BAD_DOMAIN)
      url = Egnyte::OAuthClient.authorize_url(domain:, redirect_uri: callback_url, state: new_state)
      session[:egnyte_connect_domain] = domain
      session[:egnyte_connect_return_to] = back
      redirect_to url, allow_other_host: true
    rescue Egnyte::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:egnyte_connect_oauth_state).to_s
      domain = EgnyteConnection.normalize_domain(session.delete(:egnyte_connect_domain))
      back = safe_return_to(session.delete(:egnyte_connect_return_to))
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless state_matches?(expected) && domain

      return redirect_to(back, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless EgnyteConnection.encryption_ready?

      connection = rescue_and_log(target: current_user) do
        grant = Egnyte::OAuthClient.exchange_code(domain:, code: params[:code].to_s, redirect_uri: callback_url)
        EgnyteConnection.store!(grant, domain:, username: username_for(domain, grant), by: current_user.slug)
      end
      who = connection.username ? " as #{connection.username}" : ""
      redirect_to back, notice: "Egnyte connected: #{connection.host}#{who}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Egnyte answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue Egnyte::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    rescue Egnyte::OAuthClient::Error => e
      redirect_to back, alert: "Egnyte refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    # Revokes one domain's tokens on Egnyte and deletes its row. The row goes
    # even when the revoke fails (or its tokens are unreadable); the notice
    # then says to remove the access in Egnyte.
    def disconnect
      back = safe_return_to(params[:return_to])
      connection = EgnyteConnection.find_by(domain: EgnyteConnection.normalize_domain(params[:egnyte_domain]))
      return redirect_to(back, notice: "That Egnyte domain was not connected, so nothing changed.", status: :see_other) unless connection

      revoked = revoke(connection)
      rescue_and_log(target: current_user) { connection.destroy! }
      Rails.logger.info("[egnyte_connect] disconnect domain=#{connection.domain} by=#{current_user.slug} at=#{Time.current.utc.iso8601} revoked=#{revoked}")
      notice = if revoked then "Egnyte disconnected: #{connection.host}'s tokens were revoked on Egnyte and deleted here."
               else "Egnyte disconnected: #{connection.host}'s tokens were deleted here, but Egnyte did not confirm the revoke. Remove McRitchie's access in Egnyte's settings to be sure."
               end
      redirect_to back, notice:, status: :see_other
    end

    private

    # Who signed in, read with the exchange's own access token (no refresh is
    # spent). nil when Egnyte names nobody or the read fails; the connection
    # stores either way.
    def username_for(domain, grant)
      token = grant["access_token"].presence or return nil
      Egnyte::Reader.new(domain:, token:).whoami
    rescue Egnyte::OAuthClient::Error
      nil
    end

    def revoke(connection)
      return false unless connection.readable?

      rescue_and_log(target: connection) { Egnyte::OAuthClient.revoke(connection) }
    rescue Egnyte::OAuthClient::Error
      false
    end

    # The folder this page reads for a connection: ?path= when ?egnyte_domain= names
    # it, else the Shared root.
    def browse_path(connection)
      return Egnyte::Reader::ROOT unless params[:egnyte_domain].to_s == connection.domain && params[:path].present?

      params[:path].to_s
    end

    # The page's live read, or Egnyte's error said plainly (and kept in the
    # error log: a refresh is a write). One call, two when a 401 refreshes:
    # well under Egnyte's 2 a second.
    def live_read(connection, path)
      folder = rescue_and_log(target: connection) { Egnyte::Reader.new(connection).folder(path) }
      Read.new(folder:)
    rescue Egnyte::OAuthClient::Revoked
      Read.new(error: "Egnyte no longer accepts this connection: it was revoked, expired, or the password changed. Disconnect, then connect again.")
    rescue Egnyte::OAuthClient::Error => e
      Read.new(error: e.message)
    rescue ArgumentError => e
      Read.new(error: "Not a folder this page can read: #{e.message}.")
    end

    def refusal(code)
      return "The sign-in was declined on Egnyte. Nothing was connected." if code == "access_denied"

      "Egnyte refused the sign-in (#{code[0, 100]}). Check the developer key's redirect URI, then start again."
    end

    # A return path only when it is exactly an allowed one; otherwise this page.
    def safe_return_to(value)
      RETURN_PATHS.include?(value) ? value : admin_egnyte_path
    end

    def state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:egnyte_connect_oauth_state] = state }
    end

    # The redirect registered on the Egnyte developer key: exactly this path.
    def callback_url = admin_egnyte_callback_url
  end
end
