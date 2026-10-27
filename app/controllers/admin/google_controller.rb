module Admin
  # The household's Google connections (the `sign_in` method of
  # config/integrations.yml): the ones an admin owns, and the only ones agents
  # read (GoogleConnection.household). One Google sign-in, three abilities
  # (GoogleConnection::ABILITIES), each connected and disconnected on its own.
  # /admin/google (show) is the standing page: per ability, is it connected and
  # as whom, and a live read proving it (the next week's events, the newest
  # mail, the picked Drive files, or a legacy row's newest), with Google's error said plainly; and one
  # button, Connect or Disconnect. The OAuth client and encryption keys show
  # (by NAME, never a value) only while one is missing.
  #
  # The flow itself (connect, callback, disconnect, return paths) is
  # GoogleSignIn, shared with Integrations::GoogleController, the door any
  # signed-in user connects their own account through. The callback here is
  # that shared door's too: it keeps the redirect URI Google's console has
  # registered, so it admits any signed-in user (AdminWall::SIGNED_IN) and
  # stores the connection as theirs. Every other action is admin only.
  class GoogleController < ApplicationController
    include GoogleSignIn

    before_action :require_admin, except: :callback
    # The callback's URL carries a single-use code: no cache keeps the page.
    before_action(only: :callback) { response.headers["Cache-Control"] = "no-store" }

    KEYS_NOT_SET = GoogleSignIn::KEYS_NOT_SET
    ENCRYPTION_NOT_SET = GoogleSignIn::ENCRYPTION_NOT_SET
    UNKNOWN_ABILITY = GoogleSignIn::UNKNOWN_ABILITY

    def show
      @configured = GoogleConnect::OAuthClient.configured? || !GoogleConnect::OAuthClient.sign_in_stand_in.nil?
      @encryption_ready = GoogleConnection.encryption_ready?
      @callback_url = google_callback_url
      @unreadable = GoogleConnection.household.reject(&:readable?).map(&:email)
      @sections = GoogleConnection::ABILITIES.keys.map { |ability| section(ability) }
    end

    def connect = start_google_sign_in

    def callback = finish_google_sign_in

    # Disconnects one ability from every household connection that grants it.
    def disconnect = disconnect_google(GoogleConnection.household)

    private

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
             when :drive then GoogleConnect::DriveReader.new(connection).files
             end
      [ read, nil ]
    rescue GoogleConnect::OAuthClient::Revoked
      [ nil, "Google no longer accepts this connection: it was revoked or went unused. Disconnect, then connect again." ]
    rescue GoogleConnect::OAuthClient::Error => e
      [ nil, e.message ]
    end
  end
end
