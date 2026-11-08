require "test_helper"

# [unit] ApplicationsHelper: where an /applications row goes (the Overview), and the
# app page's tab set per viewer and app (task app-page-tabs).
class ApplicationsHelperTest < ActionView::TestCase
  include Studio::CrumbsHelper

  test "[unit] an app's list row opens its Overview, for an owner and an admin alike" do
    assert_equal "/applications/commercial-welding", app_todos_path(App.new(slug: "commercial-welding"))
    assert_equal "/applications/pawsome", app_todos_path(App.new(slug: "pawsome"))
  end

  test "[unit] an owner and an admin get Overview, Pipeline and Chat, in that order" do
    pawsome = App.new(slug: "pawsome")
    assert_equal %i[overview pipeline chat], app_page_tab_keys(pawsome, admin: false)
    assert_equal %i[overview pipeline chat], app_page_tab_keys(pawsome, admin: true)
  end

  test "[unit] an owner of an unannounced app has no Pipeline tab; an admin keeps it" do
    welding = App.new(slug: AppCatalog::UNANNOUNCED.first)
    assert_equal %i[overview chat], app_page_tab_keys(welding, admin: false)
    assert_equal %i[overview pipeline chat], app_page_tab_keys(welding, admin: true)
  end

  test "[unit] an app with no CTO still has its Chat tab, which answers with the no-CTO state" do
    nocto = App.new(slug: "no-cto-app")
    assert_nil AppOwnership.cto_for_app(nocto.slug), "control: the app has no CTO"
    assert_includes app_page_tab_keys(nocto, admin: false), :chat
  end

  test "[unit] each tab links its own URL, and only the current one is marked" do
    tabs = app_page_tabs(App.new(slug: "pawsome"), admin: false, current: :pipeline)
    assert_equal [ "Overview", "Pipeline", "Chat" ], tabs.map { |t| t[:label] }
    assert_equal [ "/applications/pawsome", "/applications/pawsome/pipeline", "/applications/pawsome/chat" ], tabs.map { |t| t[:href] }
    assert_equal [ nil, "page", nil ], tabs.map { |t| t[:current] }
    assert_raises(ArgumentError) { app_page_tab_path(App.new(slug: "pawsome"), :settings) }
  end

  test "[unit] an owner's crumbs are Applications alone; an admin's run up the parent map" do
    assert_equal [ { label: "Applications", href: "/applications" } ], app_page_crumbs(admin: false)
    admin = app_page_crumbs(admin: true)
    assert_equal "/applications", admin.last[:href]
    assert_operator admin.size, :>, 1, "the admin's trail starts higher than Applications"
  end
end
