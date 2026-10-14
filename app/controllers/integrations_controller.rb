# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  # The Google Workspace card's "Sign in" row carries the hub's own Google
  # Calendar connection for an admin (Admin::GoogleCalendarController's
  # require_admin check): Connect, or the account and Disconnect. Nothing is
  # read, and nothing renders, for anyone else.
  CALENDAR_CARD = { entry: "google_workspace_connect", method: "sign_in" }.freeze

  def index
    @groups = Integration.groups
    load_calendar_connection if admin?
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end

  private

  def load_calendar_connection
    connection = GoogleCalendarConnection.current
    @calendar = {
      connection: (connection if connection&.readable?),
      connectable: (GoogleCalendar::OAuthClient.configured? || !GoogleCalendar::OAuthClient.sign_in_stand_in.nil?) &&
                   GoogleCalendarConnection.encryption_ready?
    }
  end
end
