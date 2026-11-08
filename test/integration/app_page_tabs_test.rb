require "test_helper"

# [integration] The app page's tabs (task app-page-tabs, Alex McRitchie 2026-11-07):
# /applications/:slug, /pipeline and /chat are one page, Overview | Pipeline | Chat,
# under one header. Each URL answers 200 with its own tab open, with no redirect.
# A chat for an app with no CTO yet is its no-CTO state (200), not a 404; a
# non-owner and an unknown app stay 404; an owner of an unannounced app gets no
# Pipeline tab, and its pipeline stays a 404.
class AppPageTabsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "tabs-owner@example.com", name: "Tabs Owner", role: "viewer")
    @stranger = User.create!(email: "tabs-stranger@example.com", name: "Stranger", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  def assert_tab(open, tabs: %w[overview pipeline chat])
    assert_response :success
    assert_select "[data-test='app-page-header'][data-tab='#{open}']"
    assert_select "h1", 1, "the header holds the page's one h1"
    assert_equal tabs, css_select("a[data-test='app-tab']").map { |a| a["data-tab"] }
    assert_select "a[data-test='app-tab'][aria-current='page']", 1
    assert_select "a[data-test='app-tab'][data-tab='#{open}'][aria-current='page']"
  end

  test "[integration] the Overview, Pipeline and Chat URLs each answer 200 with their own tab open" do
    log_in_as(@owner)
    get application_path("turf-monster")
    assert_tab "overview"
    assert_select "[data-test='application-page']"
    assert_select "[data-test='application-pipeline-card']", 0, "the tab replaced the Pipeline card"

    get pipeline_application_path("turf-monster")
    assert_tab "pipeline"
    assert_select "[data-test='pipeline-page']"
    assert_select "[data-test='pipeline-back']", 0, "the tabs replaced the back link"

    get chat_application_path("turf-monster")
    assert_tab "chat"
    assert_select "[data-test='cto-chat-page'] [data-test='agent-shell'][data-shell='app']"
  end

  test "[integration] an app with no CTO answers its Chat tab with the no-CTO state, 200" do
    App.create!(slug: "no-cto-app", name: "No CTO App", emoji: "🧪", position: 90)
    AppMembership.create!(app: App.find_by!(slug: "no-cto-app"), user: @owner)
    assert_nil AppOwnership.cto_for_app("no-cto-app"), "control: no CTO"

    log_in_as(@owner)
    get chat_application_path("no-cto-app")
    assert_tab "chat"
    assert_select "[data-test='cto-chat-no-cto'] [data-test='application-no-cto']", text: "This app has no CTO yet."
    assert_select "[data-test='cto-chat-page']", 0

    get application_path("no-cto-app")
    assert_select "[data-test='application-no-cto']", text: "This app has no CTO yet.", message: "the same words as the Overview"

    # The chat's other actions still need a CTO.
    post chat_application_path("no-cto-app"), params: { cto_chat: { text: "hi" } }
    assert_response :not_found
    get chat_status_application_path("no-cto-app")
    assert_response :not_found
  end

  test "[integration] a non-owner and an unknown app are still 404 on every tab" do
    log_in_as(@stranger)
    [ application_path("turf-monster"), pipeline_application_path("turf-monster"), chat_application_path("turf-monster"),
      chat_application_path("no-such-app") ].each do |path|
      get path
      assert_response :not_found, path
    end
  end

  test "[integration] an owner of an unannounced app gets no Pipeline tab, and its pipeline stays 404" do
    slug = AppCatalog::UNANNOUNCED.first
    app = App.find_by(slug: slug) || App.create!(slug: slug, name: "Commercial Welding", emoji: "🔥", position: 91)
    AppMembership.create!(app: app, user: @owner)

    log_in_as(@owner)
    get application_path(slug)
    assert_tab "overview", tabs: %w[overview chat]
    get pipeline_application_path(slug)
    assert_response :not_found

    log_in_as(users(:alex))
    get application_path(slug)
    assert_tab "overview"
  end

  test "[integration] an admin's crumbs run up the hub's map; an owner's start at Applications" do
    log_in_as(users(:alex))
    get application_path("turf-monster")
    assert_select "nav.page-header-crumbs a[href=?]", applications_path, text: "Applications"
    assert_select "nav.page-header-crumbs li", minimum: 3

    log_in_as(@owner)
    get application_path("turf-monster")
    assert_select "nav.page-header-crumbs li", 2
    assert_select "nav.page-header-crumbs [aria-current='page']", text: apps(:turf_monster).name
  end

  test "[integration] a list row on /applications opens the app's Overview" do
    log_in_as(@owner)
    get applications_path
    assert_select "[data-app='turf-monster'] a[data-test='application-link'][href=?]", application_path("turf-monster")
  end
end
