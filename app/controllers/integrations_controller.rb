# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  # The Google Calendar, Gmail and Drive cards carry a Google connection for
  # any signed-in user, each on its "Sign in" row: Connect, or the account and
  # Disconnect, under one Connect Google for all three (GOOGLE_GROUP). An admin
  # sees the household's (admin-owned) connections through /admin/google;
  # anyone else sees and manages only their own, through /integrations/google
  # (/tasks/every-user-connects-google). A signed-out visitor sees the
  # marketing cards and their contact-form Connect; nothing is read for them.
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
    return unless logged_in?

    load_google_connections
    load_fathom_connection if admin?
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end

  private

  # Does a signed-in user's card carry the real Connect or Disconnect, so its
  # contact-form Connect drops?
  def connection_card?(key)
    (@google && GOOGLE_CARDS.key?(key)) || (@fathom && key == FATHOM_CARD)
  end

  # { connectable:, own:, calendar: connection|nil, gmail: ..., drive: ... }:
  # one query, then each ability's most recent readable connection. An
  # admin's are the household's; anyone else's are their own (own: true,
  # which points the cards at /integrations/google).
  def load_google_connections
    own = !admin?
    scope = own ? current_user.google_connections : GoogleConnection.household
    connections = scope.newest_first.to_a.select(&:readable?)
    @google = GOOGLE_CARDS.values.to_h { |ability| [ ability, connections.find { _1.can?(ability) } ] }
    @google[:connectable] = GoogleSignIn.connectable?
    @google[:own] = own
  end

  # { connection: the most recent readable FathomConnection or nil, connectable: }.
  def load_fathom_connection
    @fathom = { connection: FathomConnection.readable,
                connectable: Fathom::OAuthClient.connectable? && FathomConnection.encryption_ready? }
  end
end
