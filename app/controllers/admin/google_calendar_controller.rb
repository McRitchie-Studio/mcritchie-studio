module Admin
  # The hub's Google Calendar connection (the `sign_in` method of
  # config/integrations.yml, dogfooded here before clients get it).
  # /admin/google_calendar (show) is the standing page: is an account
  # connected, as whom, with what grant, since when and by whom; can the stored
  # row still be read; are the OAuth client and encryption keys set (NAMES,
  # never a value); the next week's events as proof the read works; and the
  # two actions, Connect and Disconnect.
  #
  # /connect sends the admin to Google; /callback exchanges the code, stores
  # the connection (GoogleCalendarConnection, the refresh token encrypted) and
  # comes back to the standing page. No token, and no part of one, is
  # rendered, flashed or logged here.
  class GoogleCalendarController < ApplicationController
    before_action :require_admin
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = "Google Calendar is not set up on this server: " \
                   "#{GoogleCalendar::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
    ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                         "(#{GoogleCalendarConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Google.".freeze
    NO_CALENDAR = "Google connected the account but not its calendar: the calendar permission was unticked. " \
                  "Connect again and leave it ticked.".freeze

    def show
      @connection = GoogleCalendarConnection.current
      @readable = @connection&.readable? || false
      @configured = GoogleCalendar::OAuthClient.configured? || !GoogleCalendar::OAuthClient.sign_in_stand_in.nil?
      @encryption_ready = GoogleCalendarConnection.encryption_ready?
      @callback_url = callback_url
      load_events if @readable && @connection.can_read_calendar?
    end

    def connect
      return redirect_to(admin_google_calendar_path, alert: ENCRYPTION_NOT_SET) unless GoogleCalendarConnection.encryption_ready?

      redirect_to GoogleCalendar::OAuthClient.authorize_url(redirect_uri: callback_url, state: new_state), allow_other_host: true
    rescue GoogleCalendar::OAuthClient::NotConfigured
      redirect_to admin_google_calendar_path, alert: KEYS_NOT_SET
    end

    def callback
      expected = session.delete(:google_calendar_oauth_state)
      return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) if params[:state].blank? || params[:state] != expected
      return redirect_to(admin_google_calendar_path, alert: refusal(params[:error].to_s)) if params[:error].present?
      return redirect_to(admin_google_calendar_path, alert: ENCRYPTION_NOT_SET) unless GoogleCalendarConnection.encryption_ready?

      grant = GoogleCalendar::OAuthClient.exchange_code(code: params[:code], redirect_uri: callback_url)
      email = GoogleCalendar::OAuthClient.email_from(grant)
      return redirect_to(admin_google_calendar_path, alert: "Google did not say which account signed in, so nothing was saved. Start again.") if email.nil?

      connection = GoogleCalendarConnection.store!(grant, email:, by: current_user.slug)
      if connection.can_read_calendar?
        redirect_to admin_google_calendar_path, notice: "Google Calendar connected for #{connection.email}."
      else
        redirect_to admin_google_calendar_path, alert: NO_CALENDAR
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_google_calendar_path, alert: "Google answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}."
    rescue GoogleCalendar::OAuthClient::NotConfigured
      redirect_to admin_google_calendar_path, alert: KEYS_NOT_SET
    rescue GoogleCalendar::OAuthClient::Error => e
      redirect_to admin_google_calendar_path, alert: "Google refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
    end

    # Deletes every stored connection and asks Google to drop each grant.
    def disconnect
      connections = GoogleCalendarConnection.all.to_a
      revoked = connections.count { |connection| GoogleCalendar::OAuthClient.revoke(connection) }
      deleted = GoogleCalendarConnection.where(id: connections.map(&:id)).delete_all
      Rails.logger.info("[google_calendar] disconnect by=#{current_user.slug} at=#{Time.current.utc.iso8601} deleted=#{deleted} revoked=#{revoked}")
      notice = if deleted.zero? then "No Google Calendar connection was stored, so nothing was deleted."
               elsif revoked == deleted then "Google Calendar disconnected: deleted here and revoked at Google."
               else "Google Calendar disconnected here. Google did not confirm the revoke; remove access at myaccount.google.com to be sure."
               end
      redirect_to admin_google_calendar_path, notice:, status: :see_other
    end

    private

    def load_events
      @events = GoogleCalendar::Reader.new(@connection).events
    rescue GoogleCalendar::OAuthClient::Revoked
      @read_error = "Google no longer accepts this connection: it was revoked or went unused. Connect again."
    rescue GoogleCalendar::OAuthClient::Error => e
      @read_error = e.message
    end

    def refusal(code)
      return "The sign-in was declined on Google. Nothing was connected." if code == "access_denied"

      "Google refused the sign-in (#{code[0, 100]}). Check the OAuth client's redirect URI, then start again."
    end

    def new_state
      SecureRandom.hex(16).tap { |state| session[:google_calendar_oauth_state] = state }
    end

    def callback_url
      url_for(controller: "admin/google_calendar", action: "callback", only_path: false)
    end
  end
end
