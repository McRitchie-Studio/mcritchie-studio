module Admin
  # The hub's Microsoft 365 tenant connections (the `admin_grant` method of
  # config/integrations.yml): app-only Microsoft Graph, one row per tenant, read
  # only. It ships dark until the Entra app is registered.
  #
  # /admin/msgraph (show) is the standing page: each connected tenant by its
  # name, and a live read proving it (the first page of users, the Teams, the
  # root site and its drives), with Microsoft's error said plainly; one Connect
  # button, and a Disconnect per tenant. The app registration and encryption
  # keys show (by NAME, never a value) only while one is missing.
  #
  # /connect sends the admin to Microsoft's admin-consent page; /callback checks
  # the OAuth state and admin_consent=True, reads the organization's name with
  # an app-only token, and stores the connection (the tenant id encrypted), then
  # comes back to where Connect was pressed. No tenant id and no token is
  # rendered or flashed here. The hub's request log filters the callback's
  # `tenant` (config/initializers/filter_parameter_logging.rb), but Heroku's
  # router log still records the full callback query. A refused token or read
  # is kept in the error log (rescue_and_log) as well as said on the page. Consent is removed
  # in the tenant, not by an API, so /disconnect deletes the row and the cached
  # token and says so. A tenant is named in a form by its row id, never its id.
  #
  # WHERE IT COMES BACK. Connect and Disconnect take ?return_to=, honoured only
  # when it is exactly one of RETURN_PATHS (never an open redirect); Connect
  # keeps it in the session beside the OAuth state.
  class MsgraphController < ApplicationController
    before_action :require_admin
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "Microsoft 365 connections are not set up on this server: " \
                   "#{Msgraph::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{MsgraphConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Microsoft.".freeze
    RETURN_PATHS = %w[/integrations /admin/msgraph].freeze

    # What the standing page proves about one tenant.
    Read = Struct.new(:users, :teams, :site, :drives, keyword_init: true)
    Tenant = Struct.new(:connection, :read, :error, keyword_init: true)

    def show
      @configured = Msgraph::OAuthClient.connectable?
      @encryption_ready = MsgraphConnection.encryption_ready?
      @callback_url = callback_url
      @permissions = Msgraph::OAuthClient::PERMISSIONS
      connections = MsgraphConnection.newest_first.to_a
      @unreadable = connections.count { !_1.readable? }
      @tenants = connections.select(&:readable?).map { |connection| Tenant.new(connection:, **live_read(connection)) }
    end

    def connect
      back = safe_return_to(params[:return_to])
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless MsgraphConnection.encryption_ready?

      session[:msgraph_connect_return_to] = back
      redirect_to Msgraph::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state), allow_other_host: true
    rescue Msgraph::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:msgraph_connect_oauth_state).to_s
      back = safe_return_to(session.delete(:msgraph_connect_return_to))
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless state_matches?(expected)

      return redirect_to(back, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: "Microsoft did not report an approval. Nothing was connected.") unless params[:admin_consent].to_s.casecmp?("true")

      tenant = params[:tenant].to_s.strip.downcase
      return redirect_to(back, alert: "Microsoft's answer named no valid tenant. Nothing was connected.") unless MsgraphConnection::TENANT_ID.match?(tenant)
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless MsgraphConnection.encryption_ready?

      name = organization_name(tenant)
      connection = rescue_and_log(target: current_user) do
        MsgraphConnection.store!(tenant_id: tenant, display_name: name, by: current_user.slug)
      end
      redirect_to back, notice: "Microsoft 365 connected for #{connection.display_name}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Microsoft approved, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    end

    # Deletes one stored tenant (by row id) and its cached token. The consent
    # itself stays in the tenant until an administrator removes the app there.
    def disconnect
      back = safe_return_to(params[:return_to])
      connection = MsgraphConnection.find_by(id: params[:id])
      return redirect_to(back, notice: "That tenant was not connected, so nothing changed.", status: :see_other) unless connection

      name = connection.display_name
      rescue_and_log(target: current_user) do
        Msgraph::OAuthClient.forget!(connection.tenant_id) if connection.readable?
        connection.destroy!
      end
      Rails.logger.info("[msgraph_connect] disconnect by=#{current_user.slug} at=#{Time.current.utc.iso8601} row=#{connection.id}")
      redirect_to back, status: :see_other,
                        notice: "Microsoft 365 disconnected for #{name}: the stored connection was deleted here. " \
                                "Remove McRitchie Studio under Enterprise applications in the tenant to revoke its access."
    end

    private

    # The organization's name, read with an app-only token for the tenant just
    # consented. LABEL when the read fails (consent can take a moment to reach
    # Graph); the failure is kept in the error log, and the connection stores
    # either way.
    def organization_name(tenant)
      rescue_and_log(target: current_user) { Msgraph::Reader.new(tenant_id: tenant).organization.display_name } ||
        MsgraphConnection::LABEL
    rescue Msgraph::OAuthClient::Error
      MsgraphConnection::LABEL
    end

    # The page's live read for one tenant: one token (cached), then four reads.
    def live_read(connection)
      read = rescue_and_log(target: connection) do
        reader = Msgraph::Reader.new(connection)
        site = reader.root_site
        Read.new(users: reader.users, teams: reader.teams, site:, drives: reader.drives(site.id))
      end
      { read: }
    rescue Msgraph::OAuthClient::Revoked
      { error: "The tenant does not let the app in: the app is not found in, or not enabled for, the tenant. An administrator connects it again." }
    rescue Msgraph::OAuthClient::Error => e
      { error: e.message }
    end

    def refusal(code)
      return "The approval was declined on Microsoft. Nothing was connected." if %w[access_denied permission_denied consent_required].include?(code)

      "Microsoft refused the approval (#{code[0, 100]}). A tenant sold through GoDaddy blocks it until it is defederated; " \
        "otherwise check the app registration's redirect URI, then start again."
    end

    def safe_return_to(value)
      RETURN_PATHS.include?(value) ? value : admin_msgraph_path
    end

    def state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:msgraph_connect_oauth_state] = state }
    end

    # The redirect URI to register on the Entra app: exactly this path.
    def callback_url = admin_msgraph_callback_url
  end
end
