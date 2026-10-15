# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  # The Google Calendar, Gmail and Drive cards carry the hub's own Google
  # connection for an admin (Admin::GoogleController's require_admin check),
  # each on its "Sign in" row: Connect, or the account and Disconnect. Nothing
  # is read, and nothing renders, for anyone else.
  GOOGLE_CARDS = { "google_calendar" => :calendar, "gmail" => :gmail, "google_drive" => :drive }.freeze
  GOOGLE_METHOD = "sign_in".freeze
  # The section whose top carries Connect Google (all three at once) for an
  # admin; an admin's Google cards drop the contact-form Connect, since the
  # real Connect and Disconnect sit on them.
  GOOGLE_GROUP = "google_sign_in".freeze

  def index
    @groups = Integration.groups
    load_google_connections if admin?
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end

  private

  # { connectable:, calendar: connection|nil, gmail: ..., drive: ... }: one
  # query, then each ability's most recent readable connection.
  def load_google_connections
    connections = GoogleConnection.order(connected_at: :desc, id: :desc).to_a.select(&:readable?)
    @google = GOOGLE_CARDS.values.to_h { |ability| [ ability, connections.find { _1.can?(ability) } ] }
    @google[:connectable] = (GoogleConnect::OAuthClient.configured? || !GoogleConnect::OAuthClient.sign_in_stand_in.nil?) &&
                            GoogleConnection.encryption_ready?
  end
end
