module Admin
  # The hub's Google connection (the `sign_in` method of config/integrations.yml,
  # dogfooded here before clients get it): one Google sign-in, three abilities
  # (GoogleConnection::ABILITIES), each connected and disconnected on its own.
  # /admin/google (show) is the standing page: per ability, is it connected and
  # as whom, and a live read proving it (the next week's events, the newest
  # mail, the newest Drive files), with Google's error said plainly; and one
  # button, Connect or Disconnect. The OAuth client and encryption keys show
  # (by NAME, never a value) only while one is missing.
  #
  # /connect?ability= sends the admin to Google for that ability's one read
  # scope; /callback exchanges the code, refuses a grant without that scope,
  # stores the connection (the refresh token encrypted) and comes back to
  # where Connect was pressed. No token, and no part of one, is rendered,
  # flashed or logged here.
  #
  # WHERE IT COMES BACK. Connect and Disconnect sit on this page and on the
  # /integrations Calendar, Gmail and Drive cards. Each takes ?return_to=,
  # honoured only when it is exactly one of RETURN_PATHS (never an open
  # redirect); Connect keeps it in the session beside the OAuth state.
  class GoogleController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "Google connections are not set up on this server: " \
                   "#{GoogleConnect::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{GoogleConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Google.".freeze
    UNKNOWN_ABILITY = "Choose Google Calendar, Gmail or Google Drive to connect.".freeze
    # The only places Connect and Disconnect come back to. Exact paths, no prefix match.
    RETURN_PATHS = %w[/integrations /admin/google].freeze

    def show
      @configured = GoogleConnect::OAuthClient.configured? || !GoogleConnect::OAuthClient.sign_in_stand_in.nil?
      @encryption_ready = GoogleConnection.encryption_ready?
      @callback_url = callback_url
      @unreadable = GoogleConnection.all.reject(&:readable?).map(&:email)
      @sections = GoogleConnection::ABILITIES.keys.map { |ability| section(ability) }
    end

    def connect
      back = safe_return_to(params[:return_to])
      ability = GoogleConnection.ability(params[:ability])
      return redirect_to(back, alert: UNKNOWN_ABILITY) if ability.nil?
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless GoogleConnection.encryption_ready?

      session[:google_connect_return_to] = back
      session[:google_connect_ability] = ability.to_s
      redirect_to GoogleConnect::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state, ability:), allow_other_host: true
    rescue GoogleConnect::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:google_connect_oauth_state).to_s
      back = safe_return_to(session.delete(:google_connect_return_to))
      ability = GoogleConnection.ability(session.delete(:google_connect_ability))
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless state_matches?(expected) && ability

      name = GoogleConnection::ABILITY_NAMES.fetch(ability)
      return redirect_to(back, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless GoogleConnection.encryption_ready?

      grant = GoogleConnect::OAuthClient.exchange_code(code: params[:code], redirect_uri: callback_url)
      email = GoogleConnect::OAuthClient.email_from(grant)
      return redirect_to(back, alert: "Google did not say which account signed in, so nothing was saved. Start again.") if email.nil?
      unless grant["scope"].to_s.split.include?(GoogleConnection.scope_for(ability))
        return redirect_to(back, alert: "Google signed in #{email} but did not grant #{name}: its permission was unticked. " \
                                        "Nothing was saved. Connect again and leave it ticked.")
      end

      connection = GoogleConnection.store!(grant, email:, by: current_user.slug)
      redirect_to back, notice: "#{name} connected for #{connection.email}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Google answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue GoogleConnect::OAuthClient::NotConfigured
      redirect_to back, alert: KEYS_NOT_SET
    rescue GoogleConnect::OAuthClient::Error => e
      redirect_to back, alert: "Google refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    # Disconnects one ability from every account that grants it. Google
    # cannot revoke a single scope, so an account keeping other abilities only
    # forgets this one here; an account losing its last is revoked and deleted.
    def disconnect
      back = safe_return_to(params[:return_to])
      ability = GoogleConnection.ability(params[:ability])
      return redirect_to(back, alert: UNKNOWN_ABILITY, status: :see_other) if ability.nil?

      name = GoogleConnection::ABILITY_NAMES.fetch(ability)
      dropped, revoked, deleted = disconnect_all(ability)
      Rails.logger.info("[google_connect] disconnect ability=#{ability} by=#{current_user.slug} at=#{Time.current.utc.iso8601} " \
                        "dropped=#{dropped} deleted=#{deleted} revoked=#{revoked}")
      redirect_to back, notice: disconnect_notice(name, dropped, revoked, deleted), status: :see_other
    end

    private

    # Returns [scopes dropped, tokens revoked, rows deleted].
    def disconnect_all(ability)
      dropped = revoked = deleted = 0
      GoogleConnection.all.select { |connection| connection.can?(ability) }.each do |connection|
        if (connection.abilities - [ ability ]).any?
          connection.drop!(ability)
          dropped += 1
        else
          revoked += 1 if GoogleConnect::OAuthClient.revoke(connection)
          deleted += GoogleConnection.where(id: connection.id).delete_all
        end
      end
      [ dropped, revoked, deleted ]
    end

    def disconnect_notice(name, dropped, revoked, deleted)
      if dropped.zero? && deleted.zero? then "#{name} was not connected, so nothing changed."
      elsif deleted.zero? then "#{name} disconnected here. The account's other Google connections stay."
      elsif revoked == deleted then "#{name} disconnected: deleted here and revoked at Google."
      else "#{name} disconnected here. Google did not confirm the revoke; remove access at myaccount.google.com to be sure."
      end
    end

    Section = Struct.new(:ability, :name, :connection, :read, :error, keyword_init: true)

    # One ability's row on the standing page, with its live read or its error.
    def section(ability)
      connection = GoogleConnection.for(ability)
      read, error = connection ? read_for(ability, connection) : nil
      Section.new(ability:, name: GoogleConnection::ABILITY_NAMES.fetch(ability), connection:, read:, error:)
    end

    def read_for(ability, connection)
      read = case ability
             when :calendar then GoogleConnect::CalendarReader.new(connection).events
             when :gmail then GoogleConnect::GmailReader.new(connection).newest
             when :drive then GoogleConnect::DriveReader.new(connection).newest
             end
      [ read, nil ]
    rescue GoogleConnect::OAuthClient::Revoked
      [ nil, "Google no longer accepts this connection: it was revoked or went unused. Disconnect, then connect again." ]
    rescue GoogleConnect::OAuthClient::Error => e
      [ nil, e.message ]
    end

    def refusal(code)
      return "The sign-in was declined on Google. Nothing was connected." if code == "access_denied"

      "Google refused the sign-in (#{code[0, 100]}). Check the OAuth client's redirect URI, then start again."
    end

    # A return path only when it is exactly an allowed one; otherwise this page.
    def safe_return_to(value)
      RETURN_PATHS.include?(value) ? value : admin_google_path
    end

    def state_matches?(expected)
      params[:state].present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:google_connect_oauth_state] = state }
    end

    # The path the OAuth client registered first (/admin/google_calendar/callback):
    # kept, so the Google Cloud console owes no change.
    def callback_url = admin_google_callback_url
  end
end
