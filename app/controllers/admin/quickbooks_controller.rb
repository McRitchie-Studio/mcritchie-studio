module Admin
  # The hub's QuickBooks Online connections (the `sign_in` method of
  # config/integrations.yml, dogfooded here before clients get it): one Intuit
  # sign-in per company, one ability, reading the company's info and its
  # reports. Read only: Quickbooks::Reader holds no write path.
  #
  # /admin/quickbooks (show) is the standing page: each connected company, its
  # environment, and a live read proving it (the company's name from
  # CompanyInfo, and this year's profit and loss to date: its period, basis,
  # sections and net income), with Intuit's error said plainly; Connect (another
  # company) and a Disconnect per company. The Intuit app and encryption keys
  # show (by NAME, never a value) only while one is missing: until then Connect
  # renders disabled.
  #
  # /connect sends the admin to Intuit; /callback checks the OAuth state, takes
  # the realmId Intuit sends, exchanges the code, stores the connection (the
  # refresh token encrypted) and comes back to where Connect was pressed. No
  # token, and no part of one, is rendered, flashed or logged here; a refused
  # exchange, refresh or read is kept in the error log (rescue_and_log) as well
  # as said on the page. /disconnect revokes the grant at Intuit, then deletes
  # the row even when the revoke fails, and says which happened.
  #
  # WHERE IT COMES BACK. Each action takes ?return_to=, honoured only when it
  # is exactly one of RETURN_PATHS (never an open redirect); Connect keeps it
  # in the session beside the OAuth state.
  class QuickbooksController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "QuickBooks connections are not set up on this server: " \
                   "#{Quickbooks::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{QuickbooksConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Intuit.".freeze
    # The only places Connect and Disconnect come back to. Exact paths, no prefix match.
    RETURN_PATHS = %w[/integrations /admin/quickbooks].freeze

    # What the standing page proves about one connection: the read, or the error.
    Read = Struct.new(:connection, :company, :report, :error, keyword_init: true)

    def show
      @configured = Quickbooks::OAuthClient.connectable?
      @encryption_ready = QuickbooksConnection.encryption_ready?
      @environment = Quickbooks::OAuthClient.environment
      @callback_url = callback_url
      @unreadable = QuickbooksConnection.ordered.reject(&:readable?)
      @reads = QuickbooksConnection.readable.map { live_read(_1) }
    end

    def connect
      back = safe_return_to(params[:return_to])
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless QuickbooksConnection.encryption_ready?

      session[:quickbooks_connect_return_to] = back
      redirect_to Quickbooks::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state), allow_other_host: true
    rescue Quickbooks::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:quickbooks_connect_oauth_state).to_s
      back = safe_return_to(session.delete(:quickbooks_connect_return_to))
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless state_matches?(expected)

      return redirect_to(back, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless QuickbooksConnection.encryption_ready?
      return redirect_to(back, alert: "Intuit came back without naming a company (no realmId). Nothing was connected; start again.") if params[:realmId].blank?

      environment = Quickbooks::OAuthClient.environment
      connection = rescue_and_log(target: current_user) do
        grant = Quickbooks::OAuthClient.exchange_code(code: params[:code].to_s, redirect_uri: callback_url)
        QuickbooksConnection.store!(grant, realm_id: params[:realmId].to_s, company_name: company_name_for(grant, environment),
                                           environment:, by: current_user.slug)
      end
      redirect_to back, notice: "QuickBooks connected: #{connection.company_name} (#{connection.environment})."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Intuit answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue Quickbooks::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    rescue Quickbooks::OAuthClient::Error => e
      redirect_to back, alert: "Intuit refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    # Revokes one company's grant at Intuit, then deletes its row whatever
    # Intuit answered: the hub stops reading either way.
    def disconnect
      back = safe_return_to(params[:return_to])
      connection = QuickbooksConnection.find_by(id: params[:id])
      return redirect_to(back, notice: "That QuickBooks company was not connected, so nothing changed.", status: :see_other) unless connection

      revoked = revoke(connection)
      name = connection.company_name
      rescue_and_log(target: current_user) { connection.destroy! }
      Rails.logger.info("[quickbooks_connect] disconnect by=#{current_user.slug} at=#{Time.current.utc.iso8601} id=#{connection.id} revoked=#{revoked}")
      notice = if revoked then "QuickBooks disconnected for #{name}: Intuit revoked the grant and the stored token was deleted here."
               else "QuickBooks disconnected for #{name}: the stored token was deleted here, but Intuit did not confirm the revoke. Remove McRitchie Studio's access in QuickBooks (Settings, Manage apps) to be sure."
               end
      redirect_to back, notice:, status: :see_other
    end

    private

    # True when Intuit took the revoke; false (and kept in the error log) when not.
    def revoke(connection)
      return false unless connection.readable?

      rescue_and_log(target: connection) { Quickbooks::OAuthClient.revoke(connection) }
    rescue Quickbooks::OAuthClient::Error
      false
    end

    # The company's name from CompanyInfo, read with the exchange's own access
    # token (no refresh is spent). LABEL when Intuit names none or the read
    # fails; the connection stores either way.
    def company_name_for(grant, environment)
      token = grant["access_token"].presence or return QuickbooksConnection::LABEL
      Quickbooks::Reader.new(token:, realm_id: params[:realmId].to_s, environment:).company_info.name || QuickbooksConnection::LABEL
    rescue Quickbooks::OAuthClient::Error
      QuickbooksConnection::LABEL
    end

    # One company's live read, or Intuit's error said plainly (and kept in the
    # error log: the refresh is a write). One refresh, then two reads.
    def live_read(connection)
      today = Time.current.in_time_zone("America/Denver").to_date
      rescue_and_log(target: connection) do
        reader = Quickbooks::Reader.new(connection)
        Read.new(connection:, company: reader.company_info, report: reader.profit_and_loss(start_date: today.beginning_of_year, end_date: today))
      end
    rescue Quickbooks::OAuthClient::Revoked
      Read.new(connection:, error: "Intuit no longer accepts this connection: it was revoked, expired or its token was superseded. Disconnect, then connect again.")
    rescue Quickbooks::OAuthClient::Error => e
      Read.new(connection:, error: e.message)
    end

    def refusal(code)
      return "The sign-in was declined on Intuit. Nothing was connected." if code == "access_denied"

      "Intuit refused the sign-in (#{code[0, 100]}). Check the Intuit app's redirect URI, then start again."
    end

    # A return path only when it is exactly an allowed one; otherwise this page.
    def safe_return_to(value)
      RETURN_PATHS.include?(value) ? value : admin_quickbooks_path
    end

    def state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:quickbooks_connect_oauth_state] = state }
    end

    # The redirect URI registered on the Intuit app: exactly this path.
    def callback_url = admin_quickbooks_callback_url
  end
end
