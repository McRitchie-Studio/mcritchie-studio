require "test_helper"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [component] The hub's ops pages on the engine page header (task hub-ops-page-headers,
# split 2 of the hub's remaining hand-rolled h1 pages; split 1 is
# test/integration/sports_pages_header_test.rb). Each hand-rolled header (an eyebrow
# over an h1, a back link, or a dark topbar's h1) is now studio/page_header: the title
# is the page's one h1, the trail names the page's parent, and no header passes
# actions_html.
class OpsPagesHeaderTest < ActionDispatch::IntegrationTest
  ROW = ".page-header".freeze
  KINDS = %w[page-header-menu page-header-action page-header-tools].freeze

  setup do
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist")
  end

  # Gets the page with the engine's deprecation hook armed: no header on it may pass
  # actions_html, and every control on the right must be one of the engine's kinds.
  def get_header(path)
    sites = []
    Studio::PageHeader.stub(:warning_enabled?, true) do
      Studio::PageHeader.stub(:deprecate_actions_html, ->(site: nil, **) { sites << site }) do
        get path
      end
    end
    assert_response :success
    assert_empty sites, "#{path} passes actions_html to studio/page_header"
    css_select("#{ROW} .page-header-actions > *").each do |el|
      assert_includes KINDS, el["class"].to_s.split.first, "#{path}: a header control outside the four kinds"
    end
  end

  def crumb_hrefs = css_select("#{ROW} nav.page-header-crumbs a.page-header-crumb").map { |a| a["href"] }

  def assert_page_header(page)
    get_header page[:path]

    assert_select ROW, { count: 1 }, "#{page[:path]}: one page header"
    assert_select "h1", { count: 1 }, "#{page[:path]}: one h1 on the page"
    assert_select "#{ROW} h1.page-header-title", { count: 1, text: page[:title] }, "#{page[:path]}: the title is the header's h1"
    if page[:crumbs].empty?
      assert_select "#{ROW} nav.page-header-crumbs", { count: 0 }, "#{page[:path]}: a root page has no trail"
    else
      assert_select "#{ROW} nav.page-header-crumbs[aria-label=Breadcrumb]", { count: 1 }, "#{page[:path]}: a crumb trail"
      assert_select "#{ROW} a.page-header-parent", { count: 1 }, "#{page[:path]}: the phone's parent link"
      assert_equal page[:crumbs], crumb_hrefs, "#{page[:path]}: the trail, root first"
    end
    # The row is a direct child of the page's content container, so sticky lasts the
    # page (studio/_page_header: sticky ends where its parent ends).
    row = css_select(ROW).first
    assert_operator row.parent.css("*").size, :>, row.css("*").size + 3, "#{page[:path]}: the row shares its container with the content"
  end

  def admin = [ admin_dashboard_path ]
  def basement = [ admin_dashboard_path, admin_basement_path ]

  def admin_pages(video:, alt:)
    [
      { path: admin_egnyte_path, title: "Egnyte connections", crumbs: basement },
      { path: admin_quickbooks_path, title: "QuickBooks connection", crumbs: basement },
      { path: settings_agents_path, title: "Agents", crumbs: admin + [ applications_path ] },
      { path: settings_agent_path("turf-monster"), title: AppOwnership.ctos.find { |cto| cto.slug == "turf-monster" }.display_name,
        crumbs: admin + [ applications_path, application_path("turf-monster") ] },
      { path: applications_path, title: "Applications", crumbs: admin },
      { path: asset_browser_path, title: "Object store", crumbs: basement },
      { path: build_requests_path, title: "App requests", crumbs: admin },
      { path: credentials_path, title: "Software by entity", crumbs: basement },
      { path: stack_path, title: "Every client's stack", crumbs: basement },
      { path: stack_matrix_path, title: "Client matrix", crumbs: basement + [ stack_path ] },
      { path: videos_path, title: "Videos", crumbs: basement },
      { path: video_path(video), title: video.title, crumbs: basement + [ videos_path ] },
      { path: alt_videos_path, title: "Alt videos", crumbs: basement + [ videos_path ] },
      { path: video_alt_video_path(video, alt), title: video.title, crumbs: basement + [ videos_path, video_path(video) ] },
      { path: activities_agents_path, title: "Activities", crumbs: admin },
      { path: mason_heartbeat_path, title: "Session Activities · Mason Heartbeat", crumbs: [ deployments_path ] },
      { path: heartbeat_all_activities_path, title: "All Activities · Mason Heartbeat",
        crumbs: [ deployments_path, mason_heartbeat_path ] },
      { path: mason_insights_path, title: "💡 Insight Bank", crumbs: [ deployments_path ] },
      { path: mason_pipeline_path, title: "🍽️ Distillation Pipeline", crumbs: [ deployments_path ] }
    ]
  end

  def public_pages
    [
      { path: packages_stack_path, title: "Everything in every tier", crumbs: [ packages_path ] },
      { path: privacy_path, title: "Privacy Policy and Messaging Terms and Conditions", crumbs: [] },
      { path: terms_path, title: "Terms of Service", crumbs: [] }
    ]
  end

  test "[component] each admin ops page renders studio/page_header with its trail and exactly one h1" do
    video = LetteredVideo.seed!
    log_in_as(users(:alex))
    admin_pages(video:, alt: video.alt_videos.first).each { |page| assert_page_header(page) }
  end

  test "[component] the public pages: the full stack under Packages, the legal pages as roots" do
    public_pages.each { |page| assert_page_header(page) }
  end

  test "[component] the eyebrows and back links are gone: the old kickers end the trail instead" do
    log_in_as(users(:alex))
    { asset_browser_path => "Assets", credentials_path => "Credentials", stack_path => "Stack",
      heartbeat_all_activities_path => "All Activities", mason_insights_path => "Insight Bank" }.each do |path, label|
      get path
      assert_select "#{ROW} .page-header-crumb-current", { text: label }, "#{path}: the trail ends at #{label}"
    end
    get packages_stack_path
    assert_select "[data-test=back-to-packages]", 0
    assert_select ".hb-back", 0
  end

  test "[component] QuickBooks: Connect is the header's one action once set up, the disabled button stays in the page" do
    log_in_as(users(:alex))

    get_header admin_quickbooks_path
    if css_select("button[data-test=quickbooks-connect-disabled][disabled]").any?
      assert_select "#{ROW} a.page-header-action", 0
      assert_select "#{ROW} button", 0
    else
      assert_select "#{ROW} a.page-header-action[data-test=quickbooks-connect][href=?]", admin_quickbooks_connect_path
    end
  end

  test "[component] an owner's Applications and agent pages start the trail at Applications, never the Admin dashboard" do
    owner = User.create!(email: "header-owner@example.com", name: "Header Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    log_in_as(owner)

    get_header applications_path
    assert_select "#{ROW} nav.page-header-crumbs", 0
    get_header settings_agents_path
    assert_equal [ applications_path ], crumb_hrefs
    get_header settings_agent_path("turf-monster")
    assert_equal [ applications_path, application_path("turf-monster") ], crumb_hrefs
    assert_select "a[href=?]", admin_dashboard_path, count: 0
  end

  test "[component] the alt video: Download all assets is the header's action; the kicker and links stay below" do
    video = LetteredVideo.seed!
    alt = video.alt_videos.first
    log_in_as(users(:alex))
    get_header video_alt_video_path(video, alt)

    assert_select "#{ROW} a.page-header-action[data-test=alt-video-download-all][href=?]",
                  video_alt_video_download_path(video, alt), text: "Download all assets"
    assert_select "#{ROW} .page-header-crumb-current", text: alt.name
    assert_select "[data-test=alt-video-kicker]", /Source video · #{alt.name}/
    assert_select "[data-test=alt-video-source-link][href=?]", video_path(video)
  end

  test "[component] the dark surfaces draw the header inside their section, outside the activities feed's frame" do
    log_in_as(users(:alex))
    { mason_heartbeat_path => "#mason-heartbeat", heartbeat_all_activities_path => "#mason-heartbeat",
      mason_insights_path => "#mason-insights", mason_pipeline_path => "#mason-heartbeat",
      activities_agents_path => "#mason-heartbeat" }.each do |path, section|
      get path
      assert_select "#{section} > #{ROW}", { count: 1 }, "#{path}: the row is the section's own child"
    end
    get activities_agents_path
    assert_select "turbo-frame #{ROW}", 0
  end
end
