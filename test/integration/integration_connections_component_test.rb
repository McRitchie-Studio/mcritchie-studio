require "test_helper"

# [component] /integrations: each card with connections says how it connects
# (who each way covers, its setup and its upkeep) and what it can do, and
# names the ways behind an ability only when there is more than one.
class IntegrationConnectionsComponentTest < ActionDispatch::IntegrationTest
  def card(key) = css_select("[data-test='integration-entry'][data-entry='#{key}']").first

  test "[component] Google Workspace lists both ways with their upkeep, and its abilities with the ways" do
    get integrations_path
    assert_response :success
    google = card("google_workspace_connect")

    methods = google.css("[data-test='entry-method']")
    assert_equal %w[admin_grant sign_in], methods.map { _1["data-method"] }
    assert_includes methods.first.at_css("[data-test='method-terms']").text, "Your whole company · About 2 minutes in your admin console · No upkeep"
    assert_includes methods.last.at_css("[data-test='method-terms']").text, "One person · One click · May ask you to sign in again"
    assert_equal "true", methods.last["data-soon"]
    assert_includes methods.last.text, "Coming soon"

    calendar = google.at_css("[data-test='entry-ability'][data-ability='read_calendar']")
    assert_equal "soon", calendar["data-status"]
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
    assert_empty card("ai_features").css("[data-test='entry-connections']")
  end
end
