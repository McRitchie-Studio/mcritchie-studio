require "test_helper"

class LinksHubTest < ActionDispatch::IntegrationTest
  test "public /links shows only the Apps section behind the session wall" do
    get links_path
    assert_response :success
    assert_select "h1", "Links"
    assert_match "Turf Monster", response.body
    # Studio and Directory links are admin-only; NFL is public (public_nfl_links_test.rb)
    assert_select "a[href=?]", dashboard_path, count: 0
  end

  # A `reserved` satellite holds its port range and registry row but is not
  # linked, so the public Apps section must not draw it. rolio is archived in
  # config/apps.yml and reserved in config/satellites.yml; Turf Monster is the
  # active control that does render.
  test "[integration] a reserved satellite stays off the public Apps section" do
    rolio = Satellite.find("rolio")
    assert rolio, "precondition: rolio is registered in config/satellites.yml"
    assert_equal "reserved", rolio.status

    get links_path
    assert_response :success
    assert_match "Turf Monster", response.body, "control: an active satellite does render"
    assert_no_match "Rolio", response.body
    assert_select "a[href^=?]", rolio.url_for, count: 0
  end

  test "anonymous link sidebar exposes only the public Apps section" do
    get links_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    # A row's icon proves the visitor sections rendered (Portfolio is one link to /websites):
    # an emoji swap on the locked engine, a line icon under the glass style.
    assert_select "#studio-link-sidebar .studio-emoji-swap, #studio-link-sidebar [data-sidebar-row-icon]"
    # Studio is behind the session wall
    assert_select "#studio-link-sidebar a[href=?]", dashboard_path, count: 0
  end

  test "link sidebar panel renders the slide-in transition markup" do
    get links_path
    assert_response :success
    # The panel must slide in from off-screen right (translate-x-full -> translate-x-0),
    # not pop into place. Guards against a re-removal of the transition (see #33,
    # which stripped it to fix a browser-back snapshot bug).
    assert_match 'x-transition:enter-start="translate-x-full"', response.body
    assert_match 'x-transition:enter-end="translate-x-0"', response.body
    assert_match 'x-transition:leave-end="translate-x-full"', response.body
  end

  # The redirect sits behind require_admin in the controller, not in routes.rb, where
  # it would answer before the wall and name the Basement to anyone who asked.
  test "anonymous visitor is sent to sign-in by /admin/links, and never told of the Basement" do
    get admin_links_path
    assert_redirected_to login_path
    assert_no_match(/basement/i, response.location)
    assert_no_match(/basement/i, response.body)
  end

  test "logged-in non-admin gets the same refusal from /admin/links, and never told of the Basement" do
    log_in_as users(:viewer)
    get admin_links_path
    assert_redirected_to root_path # require_admin -> root with "Not authorized"
    assert_no_match(/basement/i, response.body)
  end

  test "an admin's /admin/links redirects to the Basement, the single page of links" do
    log_in_as users(:alex) # role: admin
    get admin_links_path
    assert_redirected_to admin_basement_path

    follow_redirect!
    assert_response :success
    assert_select "h1", "Basement"
    # The hub's only On-chain link was the Signing Console, and the section went
    # with it (/tasks/retire-signing-console). Turf Monster is the web3 hub, so
    # this one must not grow back.
    assert_no_match "Signing Console", response.body
  end

  test "anonymous visitor cannot reach /admin/basement" do
    get admin_basement_path
    assert_redirected_to login_path
  end

  test "logged-in non-admin is refused /admin/basement" do
    log_in_as users(:viewer)
    get admin_basement_path
    assert_redirected_to root_path
  end

  test "[component] an admin's Basement lists the moved pages with their descriptions, under the page header" do
    log_in_as users(:alex)
    get admin_basement_path
    assert_response :success

    assert_select "h1.page-header-title", "Basement"
    assert_select "[data-pin='page']", 1
    { admin_schema_path => "DB schema browser",
      admin_emails_path => "Transactional emails", admin_link_preview_path => "Default title",
      asset_browser_path => "Object store", stack_path => "tier and software",
      credentials_path => "vault icons", broadcasts_path => "Compose, send",
      contacts_path => "mailing list", broadcast_analytics_path => "Delivery, opens",
      error_logs_path => "Captured errors", admin_tiktok_path => "Connected account", admin_google_path => "Calendar",
      admin_fathom_path => "Meeting notes", admin_egnyte_path => "Document store", admin_agent_messages_path => "Messages to agents",
      admin_report_destinations_path => "Discord channel", admin_csp_reports_path => "Content-Security-Policy",
      builders_path => "commit pace", teams_path => "All teams", people_path => "Players + staff", docs_path => "Documentation",
      admin_ai_builder_multiple_path => "commit pace backtest", workflow_news_index_path => "Intake", merge_people_path => "Resolve duplicate",
      duplicates_people_path => "Duplicate candidates", alt_videos_path => "recast version", news_index_path => "News pipeline", contents_path => "Content pipeline",
      model_pipeline_path => "Character model", body_archetypes_path => "Body builds", videos_path => "digested video" }.each do |href, desc|
      assert_select "[data-link-hub] a[href=?]", href, text: /#{Regexp.escape(desc)}/
    end
    [ logos_path, build_requests_path, books_path, activities_agents_path ].each { |href| assert_select "[data-link-hub] a[href=?]", href, count: 0 }
  end

  test "[component] the sidebar reads Dashboard, DevOps, Design, Branding Kits, App Requests, Books, Activities, Basement, and the moved pages leave it" do
    log_in_as users(:alex)
    get admin_basement_path

    assert_select "#studio-link-sidebar a[href=?]", admin_dashboard_path, text: /Dashboard/
    assert_select "#studio-link-sidebar a[href=?]", deployments_path, text: /DevOps/
    assert_select "#studio-link-sidebar a[href=?]", admin_style_path, text: /Design/
    assert_select "#studio-link-sidebar a[href=?]", logos_path, text: /Branding Kits/
    assert_select "#studio-link-sidebar a[href=?]", build_requests_path, text: /App Requests/
    assert_select "#studio-link-sidebar a[href=?]", books_path, text: /Books/
    assert_select "#studio-link-sidebar a[href=?]", activities_agents_path, text: /Activities/
    assert_select "#studio-link-sidebar a[href=?]", admin_basement_path, text: /Basement/
    [ admin_schema_path, admin_emails_path, admin_link_preview_path, asset_browser_path, stack_path, credentials_path,
      broadcasts_path, contacts_path, broadcast_analytics_path, error_logs_path, admin_tiktok_path, admin_google_path,
      admin_fathom_path, admin_egnyte_path, admin_agent_messages_path, admin_report_destinations_path, admin_csp_reports_path ].each do |href|
      assert_select "#studio-link-sidebar a[href=?]", href, count: 0
    end
  end

  test "every moved page keeps its route and still answers an admin" do
    log_in_as users(:alex)

    [ admin_schema_path, admin_emails_path, admin_link_preview_path, asset_browser_path, stack_path, credentials_path,
      broadcasts_path, contacts_path, broadcast_analytics_path, logos_path, build_requests_path, books_path,
      activities_agents_path, error_logs_path, admin_tiktok_path, admin_google_path, admin_fathom_path, admin_egnyte_path, admin_agent_messages_path,
      admin_report_destinations_path, admin_csp_reports_path ].each do |href|
      get href
      assert_response :success, "#{href} must still answer"
    end
    assert_equal "/admin/schema", admin_schema_path
    assert_equal "schema#index", Navigation.page(:admin_schema).action_id
  end

  # What /admin/links listed stays one click away: the Admin section in the sidebar, the rest here.
  test "the sidebar's Admin section and the Basement together carry what /admin/links listed" do
    log_in_as users(:alex)
    get admin_basement_path

    [ admin_dashboard_path, deployments_path, admin_style_path, logos_path, build_requests_path, books_path,
      activities_agents_path, admin_basement_path ].each do |href|
      assert_select "#studio-link-sidebar a[href=?]", href
    end
    [ admin_schema_path, admin_emails_path, admin_link_preview_path, asset_browser_path, stack_path, credentials_path,
      broadcasts_path, contacts_path, broadcast_analytics_path, error_logs_path, admin_tiktok_path, admin_google_path,
      admin_fathom_path, admin_egnyte_path, admin_agent_messages_path, admin_report_destinations_path, admin_csp_reports_path ].each do |href|
      assert_select "[data-link-hub] a[href=?]", href
    end
  end

  # The Basement carries what the sidebar does not: the Admin section's rows stay off it.
  test "the Basement does not repeat the sidebar's Admin section" do
    log_in_as users(:alex)
    get admin_basement_path

    [ admin_dashboard_path, deployments_path, admin_style_path, logos_path, build_requests_path, books_path, activities_agents_path ].each do |href|
      assert_select "[data-link-hub] a[href=?]", href, count: 0
    end
  end

  test "[component] a visitor's sidebar and /links read Studio: Build, Chat, Portfolio, Packages, Integrations" do
    [ root_path, links_path ].each do |path|
      get path
      [ build_path, websites_path, packages_path, integrations_path ].each do |href|
        assert_select "#studio-link-sidebar a[href=?]", href, minimum: 1
      end
      assert_select "#studio-link-sidebar a", text: /App Builder/, count: 0
    end

    assert_select "[data-link-hub] h2", text: "Studio", count: 1
    assert_select "[data-link-hub] h2", text: "Services", count: 0
    [ build_path, websites_path, packages_path, integrations_path ].each { |href| assert_select "[data-link-hub] a[href=?]", href, count: 1 }
  end

  test "[component] an admin's sidebar and hubs carry no dropped page; every moved page still answers" do
    log_in_as users(:alex)
    dropped = [ dashboard_path, applications_path, agents_path, tasks_path ]
    moved = [ builders_path, news_index_path, contents_path, model_pipeline_path, body_archetypes_path, videos_path,
              teams_path, people_path, docs_path, admin_ai_builder_multiple_path, workflow_news_index_path, merge_people_path,
              duplicates_people_path, alt_videos_path ]

    get links_path
    assert_select "[data-link-hub] a[href=?]", nfl_hub_path
    assert_select "[data-link-hub] a[href=?]", packages_path
    (dropped + moved).each { |href| assert_select "[data-link-hub] a[href=?]", href, count: 0 }
    assert_select "#studio-link-sidebar a[href=?]", deployments_path
    (dropped + moved).each { |href| assert_select "#studio-link-sidebar a[href=?]", href, count: 0 }

    get admin_basement_path
    dropped.each { |href| assert_select "[data-link-hub] a[href=?]", href, count: 0 }
    moved.each { |href| assert_select "[data-link-hub] a[href=?]", href }

    (dropped + moved).each do |href|
      get href
      assert_response :success, "#{href} keeps its route"
    end
  end

  test "the cog and the identity both toggle the admin link sidebar" do
    log_in_as users(:alex)
    get dashboard_path
    assert_response :success
    assert_select "button[data-link-sidebar-trigger][aria-controls=?]", "studio-link-sidebar studio-link-sidebar-mobile"
    assert_select "[data-nav-account][data-profile-image-toggle][aria-controls=?] [data-nav-name]",
                  "studio-link-sidebar studio-link-sidebar-mobile", text: Studio.navbar_user_name_for(users(:alex))
    assert_select "#studio-link-sidebar .studio-emoji-swap-hover, #studio-link-sidebar [data-sidebar-row-icon]"
  end

  # Four one-click PNGs on /admin/style, each from a file the hub really serves, in both tones.
  test "the style guide's logo block offers the four downloads" do
    html = ApplicationController.render(partial: "style/host/logos")
    page = Nokogiri::HTML5.fragment(html)
    links = page.css("[data-download-format=png] a[data-logo-raster]")

    assert_equal %w[Favicon Favicon Stacked Stacked Nav Nav Loader Loader], links.map { |link| link["data-label"] }
    assert_equal %w[long:256 width:800 width:800 long:512], links.map { |link| link["data-raster-size"] }.each_slice(2).map(&:first)
    links.each { |link| assert_path_exists Rails.public_path.join(link["data-svg"].delete_prefix("/")), link["data-svg"] }
  end

  # The root attribute is what turns the glass cards on. The setting is guarded until the
  # release relocks an engine that has it, so a locked engine without it writes no attribute.
  test "the root carries the surface style only when the app opts in" do
    get links_path
    if Studio.respond_to?(:surface_style)
      assert_select "html[data-surface-style=?]", "glass"
    else
      assert_select "html[data-surface-style]", count: 0
    end
  end

  # Alex McRitchie, 2026-11-04: "I think 3 is my favorite nav". The setting is guarded until
  # the release relocks an engine that has it, so this reads whichever engine is locked: the
  # glass panel on one that has the style, and the plain drawer, still booting, on one that does not.
  test "the sidebar is glass when the engine has the style, and the drawer until then" do
    log_in_as users(:alex)
    get admin_dashboard_path
    assert_response :success

    if Studio.respond_to?(:sidebar_style)
      assert_select "#studio-link-sidebar[data-sidebar-glass]:not([data-sidebar-edge])"
      assert_select "#studio-link-sidebar a[aria-current=page]", count: 1 do |rows|
        assert_includes rows.first.text, "Dashboard"
      end
      assert_select "#studio-link-sidebar a[href=?] [data-sidebar-row-icon] svg", admin_dashboard_path
      assert_select "#studio-link-sidebar a[href=?] .studio-emoji-swap", admin_dashboard_path, count: 0
      assert_select "#studio-link-sidebar a[href=?] svg", logout_path
    else
      assert_select "#studio-link-sidebar[data-sidebar-glass]", count: 0
      assert_select "#studio-link-sidebar a[href=?] .studio-emoji-swap", admin_dashboard_path
    end
  end
end
