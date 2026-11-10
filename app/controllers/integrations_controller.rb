# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  # The Google Calendar, Gmail and Drive cards carry a Google connection for
  # any signed-in user, each in its action row: Connect, or the account and
  # Disconnect, under one Connect Google for all three (GOOGLE_GROUP). An admin
  # sees the household's (admin-owned) connections through /admin/google;
  # anyone else sees and manages only their own, through /integrations/google
  # (/tasks/every-user-connects-google). A signed-out visitor sees the
  # marketing cards; nothing is read for them. Their Google cards' Connect
  # opens the sign-in modal, every other card's the contact form.
  GOOGLE_CARDS = { "google_calendar" => :calendar, "gmail" => :gmail, "google_drive" => :drive }.freeze
  # A card's opt-in write abilities, each a second row under its read
  # connection (/tasks/gmail-organize-ability): Gmail's card carries Organize.
  GOOGLE_WRITE_ABILITIES = { "gmail" => [ :gmail_organize ] }.freeze
  GOOGLE_METHOD = "sign_in".freeze
  # The group whose top carries Connect Google (all three at once) for a
  # signed-in user; their Google cards drop the contact-form Connect, since the
  # real Connect and Disconnect sit on them.
  GOOGLE_GROUP = "connect".freeze
  # The Fathom card carries the hub's own Fathom connection for an admin
  # (Admin::FathomController), in its action row, the same way.
  FATHOM_CARD = "fathom".freeze
  # The Egnyte card carries the hub's Egnyte connections for an admin
  # (Admin::EgnyteController): each domain and its Disconnect, and Connect
  # (a domain field), disabled until the server holds the developer key.
  EGNYTE_CARD = "egnyte".freeze
  # The QuickBooks card carries the hub's own QuickBooks Online companies for
  # an admin (Admin::QuickbooksController), the same way; its Connect renders
  # disabled until the Intuit app is set on this server.
  QUICKBOOKS_CARD = "quickbooks".freeze
  # The Microsoft 365 card carries the hub's own tenant connections for an
  # admin (Admin::MsgraphController), in its action row, the same way. It stays
  # Coming soon for everyone else, and its Connect stays disabled until the
  # server can take a connection.
  MSGRAPH_CARD = "microsoft_365".freeze

  def index
    @groups = Integration.groups(admin: admin?)
    return unless logged_in?

    load_google_connections
    return unless admin?

    load_fathom_connection
    load_egnyte_connections
    load_quickbooks_connections
    load_msgraph_connections
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end

  private

  # { connectable:, own:, calendar: connection|nil, gmail: ..., drive: ..., gmail_organize: ... }:
  # one query, then each ability's most recent readable connection. An
  # admin's are the household's; anyone else's are their own (own: true,
  # which points the cards at /integrations/google).
  def load_google_connections
    own = !admin?
    scope = own ? current_user.google_connections : GoogleConnection.household
    connections = scope.newest_first.to_a.select(&:readable?)
    @google = (GOOGLE_CARDS.values + GOOGLE_WRITE_ABILITIES.values.flatten).to_h { |ability| [ ability, connections.find { _1.can?(ability) } ] }
    @google[:connectable] = GoogleSignIn.connectable?
    @google[:own] = own
  end

  # { connection: the most recent readable FathomConnection or nil, connectable: }.
  def load_fathom_connection
    @fathom = { connection: FathomConnection.readable,
                connectable: Fathom::OAuthClient.connectable? && FathomConnection.encryption_ready? }
  end

  # { connections: the readable EgnyteConnections by domain, connectable: }.
  def load_egnyte_connections
    @egnyte = { connections: EgnyteConnection.readable,
                connectable: Egnyte::OAuthClient.connectable? && EgnyteConnection.encryption_ready? }
  end

  # { connections: every readable QuickbooksConnection, newest first, connectable: }.
  def load_quickbooks_connections
    @quickbooks = { connections: QuickbooksConnection.readable,
                    connectable: Quickbooks::OAuthClient.connectable? && QuickbooksConnection.encryption_ready? }
  end

  # { connections: every readable MsgraphConnection, newest first, connectable: }.
  def load_msgraph_connections
    @msgraph = { connections: MsgraphConnection.readable,
                 connectable: Msgraph::OAuthClient.connectable? && MsgraphConnection.encryption_ready? }
  end
end
