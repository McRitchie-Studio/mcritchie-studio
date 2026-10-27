require "test_helper"
require "support/google_connect_fakes"
require "support/fathom_connect_fakes"

# [component] /integrations: each card with connections says how it connects
# (who each way covers, its setup and its upkeep) and what it can do, and
# names the ways behind an ability only when there is more than one. The
# Google Calendar, Gmail and Drive cards carry a connection for any signed-in
# user: Connect, or the account and Disconnect (an admin's the household's, a
# non-admin's their own); a visitor sees neither. The
# Fathom card, in its own Meeting notes section, does the same.
class IntegrationConnectionsComponentTest < ActionDispatch::IntegrationTest
  include GoogleConnectFakes
  include FathomConnectFakes

  teardown do
    reset_google_connect
    reset_fathom_connect
  end

  CARDS = { "google_calendar" => "calendar", "gmail" => "gmail", "google_drive" => "drive" }.freeze

  def card(key) = css_select("[data-test='integration-entry'][data-entry='#{key}']").first
  def slot(key) = card(key).at_css("[data-test='entry-method'][data-method='sign_in'] [data-test='google-connection']")

  test "[component] Google Workspace is the admin grant alone; Calendar, Gmail and Drive each sign in for one live read" do
    get integrations_path
    assert_response :success
    google = card("google_workspace_connect")

    assert_equal %w[admin_grant], google.css("[data-test='entry-method']").map { _1["data-method"] }
    assert_includes google.at_css("[data-test='method-terms']").text, "Your whole company · About 2 minutes in your admin console · No upkeep"
    assert_equal %w[draft_email knowledge_base], google.css("[data-test='entry-ability']").map { _1["data-ability"] }
    assert_empty google.css("[data-test='ability-via']"), "one way, so no 'via' line"

    { "google_calendar" => "read_calendar", "gmail" => "read_email", "google_drive" => "read_drive" }.each do |key, ability|
      entry = card(key)
      assert_equal "live", entry["data-status"], key
      method = entry.at_css("[data-test='entry-method']")
      assert_equal "sign_in", method["data-method"], key
      assert_includes method.at_css("[data-test='method-terms']").text, "One person · One click · May ask you to sign in again"
      assert_equal [ ability ], entry.css("[data-test='entry-ability']").map { _1["data-ability"] }, key
      assert_equal "live", entry.at_css("[data-test='entry-ability']")["data-status"]
      assert_not_includes entry.text, "Coming soon"
      assert_equal "Connect", entry.at_css("[data-test='entry-cta']").text.strip, "a visitor's CTA is the normal one"
    end
    assert_equal 1, css_select("[data-ability='read_calendar']").size, "read_calendar is on one card only"
  end

  test "[component] an entry with two ways names the ways behind each ability" do
    groups = Integration.groups
    entry = groups.find { _1.key == "integrations" }.entries.find { _1.key == "google_workspace_connect" }
    entry.connects = %w[admin_grant sign_in]
    entry.connection_methods = entry.connects.map { Integration.connection_method(_1) }
    entry.abilities += [ Integration::Ability.new(key: "read_calendar", name: "Read your calendar", via: %w[sign_in], status: "live") ]

    Integration.stub(:groups, groups) { get integrations_path }

    google = card("google_workspace_connect")
    assert_includes google.at_css("[data-ability='read_calendar'] [data-test='ability-via']").text, "Sign in"
    assert_includes google.at_css("[data-ability='draft_email'] [data-test='ability-via']").text, "Admin approval"
  end

  test "[component] a one-way entry shows no 'via' line, and an entry with no connections no block" do
    get integrations_path
    discord = card("discord")

    assert_equal 1, discord.css("[data-test='entry-method']").size
    assert_equal 2, discord.css("[data-test='entry-ability']").size
    assert_empty discord.css("[data-test='ability-via']")
    assert_equal "Post sign-ups, errors and agent updates", discord.at_css("[data-ability='post_updates']").text.squish
    assert_empty card("ai_features").css("[data-test='entry-connections']")
  end

  test "[component] a Coming soon card does not repeat Coming soon on its ways or abilities" do
    get integrations_path
    slack = card("slack")

    assert_equal "soon", slack.at_css("[data-ability='post_updates']")["data-status"] # the control: it IS soon
    assert_not_includes slack.at_css("[data-test='entry-connections']").text, "Coming soon"
  end

  test "[component] three cards render an admin the household's connect or disconnect: Connect on each when nothing is connected" do
    log_in_as users(:alex)
    with_connect_env do
      get integrations_path

      CARDS.each do |key, ability|
        assert_equal "none", slot(key)["data-state"], key
        assert_equal ability, slot(key)["data-ability"]
        link = slot(key).at_css("[data-test='google-connect']")
        assert_equal "Connect #{GoogleConnection::ABILITY_NAMES.fetch(ability.to_sym)}", link.text.strip
        assert_equal admin_google_connect_path(ability:, return_to: "/integrations"), connect_target(link), key
        assert_nil slot(key).at_css("[data-test='google-disconnect']")
      end
      assert_equal 3, css_select("[data-test='google-connection']").size, "only the three Google cards"
    end
  end

  test "[component] an admin sees the account and a confirmed Disconnect on each connected card, Connect on the rest" do
    log_in_as users(:alex)
    store_google(scope: "openid #{CALENDAR} #{DRIVE}")
    with_connect_env do
      get integrations_path

      %w[google_calendar google_drive].each do |key|
        assert_equal "connected", slot(key)["data-state"], key
        assert_equal "Connected as alex@mcritchie.studio", slot(key).at_css("[data-test='google-account']").text.squish
        form = slot(key).at_css("form[data-test='google-disconnect']")
        assert_equal admin_google_disconnect_path(ability: CARDS.fetch(key), return_to: "/integrations"), form["action"]
        assert_equal "delete", form.at_css("input[name='_method']")["value"]
        assert form["data-turbo-confirm"].present?
      end
      assert_equal "none", slot("gmail")["data-state"]
      assert slot("gmail").at_css("[data-test='google-connect']")
      assert_no_match(/synthetic-refresh/, response.body)
    end
  end

  test "[component] an admin sees no Connect when the OAuth client is not configured" do
    log_in_as users(:alex)
    with_connect_env(creds: false) do
      get integrations_path
      assert_empty css_select("[data-test='google-connect-all']"), "no Connect Google either"

      CARDS.each_key do |key|
        assert_equal "none", slot(key)["data-state"]
        assert_nil slot(key).at_css("[data-test='google-connect']")
      end
    end
  end

  def connect_all = css_select("[data-test='google-connect-all']").first

  # Where a Connect goes: a link's href, or the href the Gmail admin-trust
  # modal's Continue follows (the trigger's data-href).
  def connect_target(node) = node.name == "a" ? node["href"] : node["data-href"]

  test "[component] signed-in /integrations: the Gmail Connect is a modal trigger carrying the client ID; Calendar and Drive still link straight" do
    log_in_as users(:viewer)
    with_connect_env do
      get integrations_path

      gmail = slot("gmail").at_css("[data-test='google-connect']")
      assert_equal "button", gmail.name, "Gmail's Connect is a button, not a link to Google"
      assert_equal "gmail-admin", gmail["data-opens"]
      assert_equal "test-connect-id", gmail["data-client-id"]
      assert_equal integrations_google_connect_path(ability: :gmail, return_to: "/integrations"), gmail["data-href"]
      assert_includes gmail["@click"], "$store.modals.open('gmail-admin'"
      { "google_calendar" => :calendar, "google_drive" => :drive }.each do |key, ability|
        link = slot(key).at_css("[data-test='google-connect']")
        assert_equal "a", link.name, "#{key} links straight to Google"
        assert_equal integrations_google_connect_path(ability:, return_to: "/integrations"), link["href"]
        assert_nil link["data-opens"]
      end
      assert_no_match(/test-connect-secret/, response.body, "never the secret")
    end
  end

  test "[component] Connect the rest links straight once Gmail is connected, and opens the modal while Gmail is missing" do
    log_in_as users(:alex)
    with_connect_env do
      store_google(scope: "openid #{GMAIL}")
      get integrations_path
      button = connect_all.at_css("[data-test='google-connect-all-button']")
      assert_equal "a", button.name, "Gmail already connected: no admin modal"
      assert_nil button["data-opens"]

      GoogleConnection.delete_all
      store_google(scope: "openid #{CALENDAR}")
      get integrations_path
      button = connect_all.at_css("[data-test='google-connect-all-button']")
      assert_equal "Connect the rest", button.text.strip
      assert_equal "gmail-admin", button["data-opens"]
    end
  end

  test "[component] the Gmail trigger carries no client ID when none is set" do
    log_in_as users(:viewer)
    with_connect_env do
      ENV.delete("GOOGLE_CONNECT_CLIENT_ID")
      GoogleConnect::OAuthClient.sign_in_stand_in = Object.new # connectable without a configured client
      get integrations_path
      gmail = slot("gmail")&.at_css("[data-test='google-connect']")
      assert gmail, "Connect still shows through the stand-in"
      assert_equal "", gmail["data-client-id"].to_s
    ensure
      GoogleConnect::OAuthClient.sign_in_stand_in = nil
    end
  end

  test "[component] Connect Google sits above the three Google cards for an admin, outside their grid" do
    log_in_as users(:alex)
    with_connect_env do
      get integrations_path

      section = css_select("[data-test='integration-group'][data-group='google_sign_in']").first
      assert_equal 1, css_select("[data-test='google-connect-all']").size, "one Connect Google on the page"
      assert section.at_css("[data-test='google-connect-all']"), "in the Google section"
      assert_nil connect_all.at_css("[data-test='integration-entry']")
      assert_nil connect_all.ancestors(".grid").first, "not a cell of the card grid"
      assert_equal "none", connect_all["data-state"]
      link = connect_all.at_css("[data-test='google-connect-all-button']")
      assert_equal "Connect Google", link.text.strip
      assert_equal "gmail-admin", link["data-opens"], "Gmail is in the sign-in, so the admin-trust modal comes first"
      assert_equal admin_google_connect_path(ability: "all", return_to: "/integrations"), connect_target(link)
    end
  end

  test "[component] Connect Google becomes Connect the rest, then the account once all three are connected" do
    log_in_as users(:alex)
    with_connect_env do
      store_google(scope: "openid #{GMAIL}")
      get integrations_path
      assert_equal "some", connect_all["data-state"]
      assert_equal "Connect the rest", connect_all.at_css("[data-test='google-connect-all-button']").text.strip

      store_google(scope: "openid #{CALENDAR} #{GMAIL} #{DRIVE}")
      get integrations_path
      assert_equal "all", connect_all["data-state"]
      assert_equal "Google connected as alex@mcritchie.studio", connect_all.at_css("[data-test='google-connect-all-status']").text.squish
      assert_nil connect_all.at_css("[data-test='google-connect-all-button']")
    end
  end

  test "[component] an admin sees no contact-form Connect on the three Google cards, and keeps it elsewhere" do
    log_in_as users(:alex)
    store_google(scope: "openid #{CALENDAR}")
    with_connect_env do
      get integrations_path

      CARDS.each_key do |key|
        assert_nil card(key).at_css("[data-test='entry-cta']"), key
        assert_equal "Free", card(key).at_css("[data-test='entry-price'] p").text.strip, "#{key}: the footer keeps its price"
      end
      assert card("github_org").at_css("[data-test='entry-cta']"), "a non-Google card keeps its CTA"
      assert card("google_workspace_connect").at_css("[data-test='entry-cta']"), "the Workspace admin-grant card keeps its CTA"
    end
  end

  test "[component] a visitor sees the cards with no button and no email" do
    store_google(scope: "openid #{CALENDAR} #{GMAIL} #{DRIVE}")
    with_connect_env do
      get integrations_path
      assert_equal 3, CARDS.keys.count { card(_1) }, "the cards themselves show"
      assert_empty css_select("[data-test='google-connection']"), "visitor"
      assert_empty css_select("[data-test='google-connect-all']"), "visitor"
      CARDS.each_key do |key|
        cta = card(key).at_css("[data-test='entry-cta']")
        assert_equal "Connect", cta.text.strip, "visitor keeps #{key}'s CTA"
        assert_equal "auth", cta["data-opens"], "a visitor's #{key} Connect opens the sign-in modal"
      end
      assert_no_match(/alex@mcritchie\.studio|Connect Google|Disconnect/, response.body)
    end
  end

  test "[component] a non-admin sees their own Connect on each Google card, never the household's account" do
    store_google(scope: "openid #{CALENDAR} #{GMAIL} #{DRIVE}") # the household's, owned by the admin
    log_in_as users(:viewer)
    with_connect_env do
      get integrations_path

      CARDS.each do |key, ability|
        assert_equal "none", slot(key)["data-state"], key
        link = slot(key).at_css("[data-test='google-connect']")
        assert_equal integrations_google_connect_path(ability:, return_to: "/integrations"), connect_target(link), key
        assert_nil card(key).at_css("[data-test='entry-cta']"), "#{key}: their real Connect replaces the contact-form one"
      end
      all = css_select("[data-test='google-connect-all']").first
      assert_equal "none", all["data-state"]
      assert_equal integrations_google_connect_path(ability: GoogleConnection::ALL, return_to: "/integrations"),
                   connect_target(all.at_css("[data-test='google-connect-all-button']"))
      assert_no_match(/alex@mcritchie\.studio/, response.body, "the household's account never shows to a non-admin")
      assert_no_match(%r{/admin/google}, response.body)
      assert card("github_org").at_css("[data-test='entry-cta']"), "a non-Google card keeps its CTA"
      assert_empty css_select("[data-test='fathom-connection']"), "Fathom stays admin only"
    end
  end

  test "[component] a non-admin sees their own connected account and a Disconnect scoped to them" do
    store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: users(:viewer), refresh_token: "1//viewer-synthetic")
    log_in_as users(:viewer)
    with_connect_env do
      get integrations_path

      assert_equal "connected", slot("google_calendar")["data-state"]
      assert_equal "Connected as viewer@gmail.test", slot("google_calendar").at_css("[data-test='google-account']").text.squish
      form = slot("google_calendar").at_css("form[data-test='google-disconnect']")
      assert_equal integrations_google_disconnect_path(ability: :calendar, return_to: "/integrations"), form["action"]
      assert_equal "none", slot("gmail")["data-state"]
      assert_equal "some", css_select("[data-test='google-connect-all']").first["data-state"]
      assert_no_match(/viewer-synthetic/, response.body)
    end
  end

  # --- who reads it (/tasks/google-connect-hardening-polish) ---

  test "[component] /integrations says who reads each connection: agents for the household's, only the owner for a non-admin's" do
    store_google(scope: "openid #{CALENDAR}") # the household's, owned by the admin
    store_google(email: "viewer@gmail.test", scope: "openid #{CALENDAR}", user: users(:viewer))
    with_connect_env do
      log_in_as users(:alex)
      get integrations_path
      assert_equal "Your agents can read this", slot("google_calendar").at_css("[data-test='google-who-reads']").text.squish
      assert_equal "agents", slot("google_calendar").at_css("[data-test='google-who-reads']")["data-reader"]
      assert_nil slot("gmail").at_css("[data-test='google-who-reads']"), "no line where nothing is connected"

      log_in_as users(:viewer)
      get integrations_path
      assert_equal "Only you can see this", slot("google_calendar").at_css("[data-test='google-who-reads']").text.squish
      assert_equal "owner", slot("google_calendar").at_css("[data-test='google-who-reads']")["data-reader"]
    end
  end

  test "[component] /integrations tells a client app's owner that their app's agent reads their connection in their chat" do
    owner = User.create!(email: "app-owner@example.com", name: "App Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    store_google(email: "owner@gmail.test", scope: "openid #{CALENDAR}", user: owner)
    with_connect_env do
      log_in_as owner
      get integrations_path
      line = slot("google_calendar").at_css("[data-test='google-who-reads']")
      assert_equal "Your app's agent can read this when you chat with it", line.text.squish
      assert_equal "app_agent", line["data-reader"]
    end
  end

  def fathom_slot = card("fathom").at_css("[data-test='entry-method'][data-method='sign_in'] [data-test='fathom-connection']")

  test "[component] Fathom card shows Connect for admin only" do
    with_fathom_env do
      get integrations_path
      section = css_select("[data-test='integration-group'][data-group='meeting_notes']").first
      assert section.at_css("[data-test='integration-entry'][data-entry='fathom']"), "the card sits in Meeting notes"
      assert_equal "Sign in", section.at_css("[data-test='group-kicker']").text.strip
      assert_equal %w[sign_in], card("fathom").css("[data-test='entry-method']").map { _1["data-method"] }
      assert_equal %w[read_meeting_notes], card("fathom").css("[data-test='entry-ability']").map { _1["data-ability"] }
      assert_equal "emoji", card("fathom").at_css("[data-test='entry-lead']")["data-lead"]
      assert_empty css_select("[data-test='fathom-connection']"), "visitor"
      assert_equal "Connect", card("fathom").at_css("[data-test='entry-cta']").text.strip, "a visitor's CTA is the normal one"
      assert_no_match(/Connect Fathom/, response.body)

      log_in_as users(:viewer)
      get integrations_path
      assert_empty css_select("[data-test='fathom-connection']"), "non-admin"
      assert card("fathom").at_css("[data-test='entry-cta']"), "non-admin keeps the CTA"

      log_in_as users(:alex)
      get integrations_path
      assert_equal "none", fathom_slot["data-state"]
      link = fathom_slot.at_css("a[data-test='fathom-connect']")
      assert_equal "Connect Fathom", link.text.strip
      assert_equal admin_fathom_connect_path(return_to: "/integrations"), link["href"]
      assert_nil card("fathom").at_css("[data-test='entry-cta']"), "the admin's real Connect replaces the contact-form one"
      assert_equal "Free", card("fathom").at_css("[data-test='entry-price'] p").text.strip, "the footer keeps its price"
      assert_equal 1, css_select("[data-test='fathom-connection']").size, "only the Fathom card"
    end
  end

  test "[component] an admin sees the Fathom account and a confirmed Disconnect once connected" do
    log_in_as users(:alex)
    store_fathom(account: "alex@mcritchie.studio", refresh_token: "fathom-synthetic-refresh")
    with_fathom_env do
      get integrations_path

      assert_equal "connected", fathom_slot["data-state"]
      assert_equal "Connected as alex@mcritchie.studio", fathom_slot.at_css("[data-test='fathom-account']").text.squish
      form = fathom_slot.at_css("form[data-test='fathom-disconnect']")
      assert_equal admin_fathom_disconnect_path(return_to: "/integrations"), form["action"]
      assert_equal "delete", form.at_css("input[name='_method']")["value"]
      assert form["data-turbo-confirm"].present?
      assert_nil fathom_slot.at_css("[data-test='fathom-connect']")
      assert_no_match(/fathom-synthetic-refresh/, response.body)
    end
  end

  test "[component] an admin sees no Connect Fathom when the OAuth app is not set" do
    log_in_as users(:alex)
    with_fathom_env(creds: false) do
      get integrations_path

      assert_equal "none", fathom_slot["data-state"]
      assert_nil fathom_slot.at_css("[data-test='fathom-connect']")
    end
  end
end
