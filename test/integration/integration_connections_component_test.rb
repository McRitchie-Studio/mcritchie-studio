require "test_helper"
require "support/google_calendar_fakes"

# [component] /integrations: each card with connections says how it connects
# (who each way covers, its setup and its upkeep) and what it can do, and
# names the ways behind an ability only when there is more than one.
class IntegrationConnectionsComponentTest < ActionDispatch::IntegrationTest
  include GoogleCalendarFakes

  teardown { reset_google_calendar }

  def sign_in_row = card("google_workspace_connect").at_css("[data-test='entry-method'][data-method='sign_in']")
  def store_connection(email: "alex@mcritchie.studio") = GoogleCalendarConnection.store!(token_grant(email:).transform_keys(&:to_s), email:, by: "alex")

  def card(key) = css_select("[data-test='integration-entry'][data-entry='#{key}']").first

  test "[component] Google Workspace lists both ways with their upkeep, and its abilities with the ways" do
    get integrations_path
    assert_response :success
    google = card("google_workspace_connect")

    methods = google.css("[data-test='entry-method']")
    assert_equal %w[admin_grant sign_in], methods.map { _1["data-method"] }
    assert_includes methods.first.at_css("[data-test='method-terms']").text, "Your whole company · About 2 minutes in your admin console · No upkeep"
    assert_includes methods.last.at_css("[data-test='method-terms']").text, "One person · One click · May ask you to sign in again"
    assert_equal "false", methods.last["data-soon"]
    assert_not_includes methods.last.text, "Coming soon"

    calendar = google.at_css("[data-test='entry-ability'][data-ability='read_calendar']")
    assert_equal "live", calendar["data-status"]
    assert_not_includes calendar.text, "Coming soon"
    assert_includes calendar.at_css("[data-test='ability-via']").text, "Sign in"
    draft = google.at_css("[data-test='entry-ability'][data-ability='draft_email']")
    assert_includes draft.at_css("[data-test='ability-via']").text, "Admin approval"
    assert_not_includes draft.text, "Coming soon"
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

  test "[component] an admin sees Connect on the Sign in row when nothing is connected, and it comes back here" do
    log_in_as users(:alex)
    with_connect_env do
      get integrations_path

      row = sign_in_row
      assert_equal "none", row.at_css("[data-test='calendar-connection']")["data-state"]
      link = row.at_css("a[data-test='calendar-connect']")
      assert_equal "Connect Google Calendar", link.text.strip
      assert_equal admin_google_calendar_connect_path(return_to: "/integrations"), link["href"]
      assert_nil row.at_css("[data-test='calendar-disconnect']")
      assert_equal 1, css_select("[data-test='calendar-connection']").size, "only the Google Workspace card's Sign in row"
    end
  end

  test "[component] an admin sees the account and a confirmed Disconnect when connected" do
    log_in_as users(:alex)
    store_connection
    with_connect_env do
      get integrations_path

      row = sign_in_row
      assert_equal "connected", row.at_css("[data-test='calendar-connection']")["data-state"]
      assert_equal "Connected as alex@mcritchie.studio", row.at_css("[data-test='calendar-account']").text.squish
      form = row.at_css("form[data-test='calendar-disconnect']")
      assert_equal admin_google_calendar_disconnect_path(return_to: "/integrations"), form["action"]
      assert_equal "delete", form.at_css("input[name='_method']")["value"]
      assert_match(/revokes it at Google/, form["data-turbo-confirm"])
      assert_nil row.at_css("[data-test='calendar-connect']")
      assert_no_match(/synthetic-refresh/, response.body)
    end
  end

  test "[component] an admin sees no Connect when the OAuth client is not configured" do
    log_in_as users(:alex)
    with_connect_env(creds: false) do
      get integrations_path

      assert_equal "none", sign_in_row.at_css("[data-test='calendar-connection']")["data-state"]
      assert_nil sign_in_row.at_css("[data-test='calendar-connect']")
    end
  end

  test "[component] a visitor and a non-admin see today's page: no button, no email" do
    store_connection
    with_connect_env do
      get integrations_path
      assert_empty css_select("[data-test='calendar-connection']"), "visitor"
      assert_no_match(/alex@mcritchie\.studio|Connect Google Calendar/, response.body)

      log_in_as users(:viewer)
      get integrations_path
      assert_empty css_select("[data-test='calendar-connection']"), "non-admin"
      assert_no_match(/alex@mcritchie\.studio|Connect Google Calendar/, response.body)
    end
  end
end
