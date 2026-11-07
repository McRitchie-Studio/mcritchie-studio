require "test_helper"

# [component] applications/_page_header (task app-page-tabs): the app page's one
# header, on studio-engine's studio/_page_header. The badge and the name are the
# h1, the crumb trail ends with the app's name, and the tabs mark the open one.
class AppPageHeaderComponentTest < ActionView::TestCase
  setup { @app = App.new(slug: "pawsome", name: "Pawsome", emoji: "🐶", color: "#16A34A") }

  def render_header(current:, admin: false, app: @app)
    @rendered = +""
    render partial: "applications/page_header", locals: { app: app, admin: admin, current: current }
  end

  test "[component] each tab renders the shared header with its own tab current" do
    { overview: "/applications/pawsome", pipeline: "/applications/pawsome/pipeline", chat: "/applications/pawsome/chat" }.each do |key, href|
      render_header(current: key)
      assert_select "[data-test='app-page-header'][data-app='pawsome'][data-tab='#{key}']"
      assert_select "h1", 1
      assert_select "h1 [data-test='app-page-title'] [data-test='app-badge']", text: "🐶"
      assert_select "h1 [data-test='app-page-title']", text: /Pawsome/
      assert_select "nav.page-header-tabs[aria-label='Pawsome views'] a[data-test='app-tab']", 3
      assert_select "a[data-test='app-tab'][aria-current='page']", 1
      assert_select "a[data-test='app-tab'][data-tab='#{key}'][aria-current='page'][href='#{href}']", text: key.to_s.titleize
      assert_select "nav.page-header-crumbs [aria-current='page']", text: "Pawsome"
      assert_select "nav.page-header-crumbs a[href='/applications']", text: "Applications"
      assert_select ".page-header-actions", 0, "tabs only: no actions_html, no action"
    end
  end

  test "[component] an owner of an unannounced app sees no Pipeline tab" do
    render_header(current: :overview, app: App.new(slug: AppCatalog::UNANNOUNCED.first, name: "Welding"))
    assert_select "a[data-test='app-tab']", 2
    assert_select "a[data-test='app-tab'][data-tab='pipeline']", 0
  end
end
