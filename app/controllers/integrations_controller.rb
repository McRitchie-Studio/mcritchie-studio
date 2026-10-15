# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  # The Google Calendar, Gmail and Drive cards carry the hub's own Google
  # connection for an admin (Admin::GoogleController's require_admin check),
  # each on its "Sign in" row: Connect, or the account and Disconnect, under one
  # Connect Google for all three (GOOGLE_GROUP). Nothing is read, and nothing
  # renders, for anyone else.
  GOOGLE_CARDS = { "google_calendar" => :calendar, "gmail" => :gmail, "google_drive" => :drive }.freeze
  GOOGLE_METHOD = "sign_in".freeze
  # The section whose top carries Connect Google (all three at once) for an
  # admin; an admin's Google cards drop the contact-form Connect, since the
  # real Connect and Disconnect sit on them.
  GOOGLE_GROUP = "google_sign_in".freeze
  # The Fathom card carries the hub's own Fathom connection for an admin
  # (Admin::FathomController), on its "Sign in" row, the same way.
  FATHOM_CARD = "fathom".freeze

  helper_method :connection_card?

  def index
    @groups = Integration.groups
    return unless admin?

    load_google_connections
    load_fathom_connection
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end

  private

  # Does an admin's card carry the real Connect or Disconnect, so its
  # contact-form Connect drops?
  def connection_card?(key)
    (@google && GOOGLE_CARDS.key?(key)) || (@fathom && key == FATHOM_CARD)
  end

  # { connectable:, calendar: connection|nil, gmail: ..., drive: ... }: one
  # query, then each ability's most recent readable connection.
  def load_google_connections
    connections = GoogleConnection.order(connected_at: :desc, id: :desc).to_a.select(&:readable?)
    @google = GOOGLE_CARDS.values.to_h { |ability| [ ability, connections.find { _1.can?(ability) } ] }
    @google[:connectable] = (GoogleConnect::OAuthClient.configured? || !GoogleConnect::OAuthClient.sign_in_stand_in.nil?) &&
                            GoogleConnection.encryption_ready?
  end

  # { connection: the most recent readable FathomConnection or nil, connectable: }.
  def load_fathom_connection
    @fathom = { connection: FathomConnection.readable,
                connectable: Fathom::OAuthClient.connectable? && FathomConnection.encryption_ready? }
  end
end
