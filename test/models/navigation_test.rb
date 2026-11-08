require "test_helper"

# [unit] The navigation registry (config/navigation.yml, app/models/navigation.rb).
# The registry is the admin wall's public page list, so what it refuses to load
# matters as much as what it holds.
class NavigationTest < ActiveSupport::TestCase
  def registry_data
    YAML.safe_load_file(Navigation::PATH)
  end

  def minimal(pages: nil, sidebar: [], sub_navs: {})
    pages ||= { "tasks" => { "page" => "tasks#index", "audience" => "admin", "label" => "Tasks" },
                "root" => { "page" => "landing#index", "audience" => "public", "label" => "Home" } }
    { "pages" => pages, "sidebar" => sidebar, "sub_navs" => sub_navs }
  end

  def named_routes = Rails.application.routes.named_routes

  test "[unit] every registry page names a route that serves its declared controller action" do
    assert Navigation.pages.size > 60, "expected the whole registry, got #{Navigation.pages.size} pages"
    assert_empty Navigation.registry.route_mismatches(named_routes)
  end

  test "[unit] control: a page whose declared action is not its route's is reported" do
    wrong = Navigation.new(minimal(pages: {
      "tasks" => { "page" => "landing#index", "audience" => "public", "label" => "Tasks" },
      "no_such_route" => { "page" => "tasks#index", "audience" => "admin", "label" => "Gone" }
    }))

    assert_equal [ "tasks: declared landing#index, the route serves tasks#index",
                   "no_such_route: no route is named no_such_route" ],
                 wrong.route_mismatches(named_routes)
  end

  test "[unit] every page a nav places generates its path" do
    view = Rails.application.routes.url_helpers
    paths = Navigation.placed_keys.to_h { |key| [ key, Navigation.page(key).path(view) ] }

    assert_equal "/devops/tasks", paths.fetch("tasks")
    assert_equal "/games/2026", paths.fetch("games_season")
    assert_equal "/error_logs", paths.fetch("error_logs")
    assert paths.values.all? { |path| path.start_with?("/") }
  end

  test "[unit] an empty or missing registry does not load" do
    [ nil, false, "", [], {}, { "pages" => nil }, { "pages" => {} }, { "sidebar" => [] } ].each do |data|
      error = assert_raises(Navigation::Invalid, "#{data.inspect} must be refused") { Navigation.new(data) }
      assert_match "empty", error.message
    end

    error = assert_raises(Navigation::Invalid) { Navigation.load_file(Rails.root.join("config/no-such-navigation.yml")) }
    assert_match "missing", error.message
    assert_kind_of Hash, Navigation.load_file, "control: the shipped file loads"
  end

  test "[unit] a registry that opens no public page does not load" do
    admin_only = minimal(pages: { "tasks" => { "page" => "tasks#index", "audience" => "admin", "label" => "Tasks" } })
    error = assert_raises(Navigation::Invalid) { Navigation.new(admin_only) }
    assert_match "no public page", error.message

    assert_includes Navigation.public_actions.fetch("landing"), "index", "control: the shipped registry opens the landing page"
  end

  test "[unit] an audience other than public, admin or signed_in does not load" do
    [ nil, "", "Public", "everyone", "signed-in", "owner", true ].each do |audience|
      data = minimal(pages: { "tasks" => { "page" => "tasks#index", "audience" => audience, "label" => "Tasks" } })
      error = assert_raises(Navigation::Invalid, "audience #{audience.inspect} must be refused") { Navigation.new(data) }
      assert_match "audience must be public, admin or signed_in", error.message
    end
  end

  test "[unit] a page with no controller action, or no label, does not load" do
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(pages: { "tasks" => { "page" => "tasks", "audience" => "admin", "label" => "Tasks" } }))
    end
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(pages: { "tasks" => { "page" => "tasks#index", "audience" => "admin" } }))
    end
  end

  test "[unit] one controller action declared under two keys does not load" do
    data = minimal(pages: {
      "tasks" => { "page" => "tasks#index", "audience" => "admin", "label" => "Tasks" },
      "board" => { "page" => "tasks#index", "audience" => "public", "label" => "Board" }
    })

    assert_match "declared twice: tasks#index", assert_raises(Navigation::Invalid) { Navigation.new(data) }.message
  end

  test "[unit] a placement or a condition naming an unknown page does not load" do
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sidebar: [ { "title" => "Site", "group" => "admin", "pages" => %w[tasks nowhere] } ]))
    end
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sub_navs: { "board" => { "style" => "links", "items" => [ { "page" => "nowhere" } ] } }))
    end
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sub_navs: { "board" => { "style" => "links",
                                                      "items" => [ { "page" => "tasks", "only" => %w[nowhere] } ] } }))
    end
  end

  test "[unit] an unknown sidebar group or sub-nav style does not load" do
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sidebar: [ { "title" => "Site", "group" => "everyone", "pages" => %w[tasks] } ]))
    end
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sub_navs: { "board" => { "style" => "tabs", "items" => [] } }))
    end
  end

  test "[unit] public_actions holds the public pages only, grouped by controller" do
    registry = Navigation.new(minimal(pages: {
      "root" => { "page" => "landing#index", "audience" => "public", "label" => "Home" },
      "terms" => { "page" => "landing#terms", "audience" => "public", "label" => "Terms" },
      "tasks" => { "page" => "tasks#index", "audience" => "admin", "label" => "Tasks" }
    }))

    assert_equal({ "landing" => %w[index terms] }, registry.public_actions)
  end

  test "[unit] control: flipping one admin page to public changes the derived public set" do
    data = registry_data
    assert_equal "admin", data.dig("pages", "tasks", "audience")
    data["pages"]["tasks"]["audience"] = "public"

    opened = Navigation.new(data).public_actions

    assert_includes opened.fetch("tasks"), "index"
    assert_not_equal Navigation.public_actions, opened
    assert_nil Navigation.public_actions["tasks"]
  end

  test "[unit] an item shows by its only, except and hide_when_current rules" do
    registry = Navigation.new(minimal(sub_navs: { "board" => { "style" => "links", "items" => [
      { "page" => "tasks", "only" => %w[root] },
      { "page" => "tasks", "except" => %w[root] },
      { "page" => "tasks", "hide_when_current" => true }
    ] } }))
    only, except, hides = registry.sub_nav("board").items

    assert only.shown_on?("root")
    assert_not only.shown_on?("tasks")
    assert_not except.shown_on?("root")
    assert except.shown_on?("tasks")
    assert hides.shown_on?("root")
    assert_not hides.shown_on?("tasks")
  end

  # The two dashboards point at different pages, so they carry different names. The
  # Admin section shortens its own to Dashboard, and /dashboard is placed in no section.
  test "[unit] no two sidebar entries share a label" do
    labels = (Navigation.sidebar(:admin) + Navigation.sidebar(:general)).flat_map(&:pages).map(&:label)

    assert_equal labels.uniq, labels
    assert_includes labels, "Dashboard"
    assert_not_includes labels, "Studio dashboard"
    assert_equal "Studio dashboard", Navigation.page(:dashboard).label
    assert_equal "Admin dashboard", Navigation.page(:admin_dashboard).label
    assert_not_equal Navigation.page(:dashboard).action_id, Navigation.page(:admin_dashboard).action_id
  end

  # The dropped pages stay in the registry, which is the wall's page list and the route check.
  test "[unit] the dropped Studio pages are placed in no section, yet the registry and their routes keep them" do
    section_keys = (Navigation.sidebar(:admin) + Navigation.sidebar(:general) + Navigation.sidebar(:basement)).flat_map(&:pages).map(&:key)

    assert_includes section_keys, "deployments", "control: every section is read"
    assert_empty section_keys & %w[dashboard applications agents tasks]
    assert_empty Navigation.registry.route_mismatches(named_routes).grep(/\A(dashboard|applications|agents|tasks):/)
    assert_equal %w[dashboard applications agents tasks], %w[dashboard applications agents tasks].select { |key| Navigation.pages.key?(key) }
    assert_equal "/dashboard", Rails.application.routes.url_helpers.dashboard_path
    assert_equal %w[Admin], Navigation.sidebar(:admin).map(&:title)
    assert_equal %w[NFL], Navigation.sidebar(:general).map(&:title)
    assert_equal "Build", Navigation.page(:build).label
    assert_not_includes Navigation.sidebar(:basement).map(&:title), "Studio", "Studio names the public section LinkTreeHelper draws"
  end

  # The link sidebar draws these sections' titles (Alex McRitchie, 2026-11-04).
  test "[unit] Admin asks for a header, and no NFL or Basement section does" do
    assert_equal [ true ], Navigation.sidebar(:admin).map(&:header)
    assert_equal [ false ], Navigation.sidebar(:general).map(&:header)
    assert Navigation.sidebar(:basement).any?, "control: the Basement has sections"
    assert Navigation.sidebar(:basement).none?(&:header)
  end

  test "[unit] a section entry can override a page's label there, and only there" do
    registry = Navigation.new(minimal(sidebar: [
      { "title" => "Admin", "group" => "admin", "pages" => [ { "page" => "tasks", "label" => "Board" }, "root" ] },
      { "title" => "Other", "group" => "general", "pages" => [ "tasks", { "page" => "root" } ] }
    ]))
    admin, general = registry.sidebar(:admin).first, registry.sidebar(:general).first

    assert_equal [ "Board", "Home" ], admin.pages.map(&:label)
    assert_equal [ "Tasks", "Home" ], general.pages.map(&:label)
    assert_equal "Tasks", registry.page(:tasks).label
    assert_equal %w[tasks root], admin.pages.map(&:key)
    assert_equal "/devops/tasks", admin.pages.first.path(Rails.application.routes.url_helpers), "the override moves no route"
    assert_equal %w[tasks root], registry.placed_keys
  end

  test "[unit] the Admin section's short words stay in that section: the pages keep theirs for the sub-navs" do
    assert_equal [ "Dashboard", "DevOps", "Design", "Branding Kits", "App Requests", "Books", "Activities", "Basement" ], Navigation.sidebar(:admin).first.pages.map(&:label)
    assert_equal "Admin", Navigation.sidebar(:admin).first.title

    assert_equal "Admin dashboard", Navigation.page(:admin_dashboard).label
    assert_equal "Deployments", Navigation.page(:deployments).label
    assert_equal "Design System", Navigation.page(:admin_style).label
    assert_equal "App requests", Navigation.page(:build_requests).label
    assert_equal "Admin dashboard", Navigation.sub_nav(:board_sections).items.first.text
    assert_equal "Deployments", Navigation.sub_nav(:board_views).items.last.text
  end

  test "[unit] a section entry naming an unknown page does not load" do
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sidebar: [ { "title" => "Admin", "group" => "admin", "pages" => [ { "page" => "nowhere", "label" => "Gone" } ] } ]))
    end
    assert_raises(Navigation::Invalid) do
      Navigation.new(minimal(sidebar: [ { "title" => "Admin", "group" => "admin", "pages" => [ { "label" => "No page" } ] } ]))
    end
  end

  test "[unit] the basement group holds the moved pages, every one an admin page placed nowhere in the sidebar" do
    assert_equal %w[admin_schema admin_emails admin_link_preview asset_browser stack credentials broadcasts contacts broadcast_analytics
                    error_logs admin_tiktok admin_google admin_fathom admin_egnyte admin_msgraph admin_quickbooks admin_agent_messages admin_report_destinations admin_csp_reports admin_upgrade_proposals
                    teams people builders docs admin_ai_builder_multiple workflow_news_index merge_people duplicates_people
                    news_index contents model_pipeline body_archetypes videos alt_videos],
                 Navigation.sidebar(:basement).flat_map(&:pages).map(&:key)
    assert Navigation.sidebar(:basement).flat_map(&:pages).all? { |page| page.audience == "admin" }

    sidebar_keys = (Navigation.sidebar(:admin) + Navigation.sidebar(:general)).flat_map(&:pages).map(&:key)
    assert_empty Navigation.sidebar(:basement).flat_map(&:pages).map(&:key) & sidebar_keys
    assert_includes Navigation.placed_keys, "asset_browser", "a Basement page is still placed, so the wall test walks it"
    assert_includes Navigation.placed_keys, "admin_basement"
  end

  # ---- parent: the crumb trail's map (config/initializers/studio_crumbs.rb) ----

  def with_parents(parents, crumbs = {})
    data = minimal
    parents.each { |key, parent| data["pages"][key]["parent"] = parent }
    crumbs.each { |key, crumb| data["pages"][key]["crumb"] = crumb }
    data
  end

  test "[unit] a parent that is not a page, or a loop of parents, does not load" do
    assert_match "parent \"nowhere\" is not a page",
                 assert_raises(Navigation::Invalid) { Navigation.new(with_parents("tasks" => "nowhere")) }.message
    assert_match "parents loop",
                 assert_raises(Navigation::Invalid) { Navigation.new(with_parents("tasks" => "root", "root" => "tasks")) }.message
  end

  test "[unit] the registry draws the crumb map: each page, its crumb label and its parent" do
    registry = Navigation.new(with_parents({ "tasks" => "root" }, { "root" => "Start" }))
    crumbs = registry.draw_crumbs(Studio::Crumbs.new)

    assert_equal %i[root tasks], crumbs.chain(:tasks)
    view = Object.new.tap { |v| v.define_singleton_method(:root_path) { "/" } }
    assert_equal [ { label: "Start", href: "/" } ], crumbs.trail(view, :tasks)
  end

  # devops-namespace (Alex McRitchie, 2026-11-07): the board home is the root of its
  # own trail, "DevOps", not a child of the admin dashboard.
  test "[unit] the real registry gives every board page the trail DevOps" do
    crumbs = Navigation.registry.draw_crumbs(Studio::Crumbs.new)
    %i[tasks stages epics triage intelligence recent_tasks all_deployments mason_pipeline mason_insights
       review_events_hub].each do |key|
      assert_equal %i[deployments], crumbs.chain(key)[0...-1], key
    end
    assert_equal "DevOps", Navigation.page(:deployments).crumb_label
    assert_nil Navigation.page(:deployments).parent, "the DevOps board home is a root"
    assert_equal "Admin", Navigation.page(:admin_dashboard).crumb_label
    assert_nil Navigation.page(:admin_dashboard).parent, "the admin dashboard is the root"
  end

  # hub-remaining-page-headers: each NFL page's old back link read "NFL Hub", so the
  # registry names nfl_hub as its parent, and the hub is a root.
  test "[unit] the real registry gives every page under the NFL Hub the trail NFL Hub" do
    crumbs = Navigation.registry.draw_crumbs(Studio::Crumbs.new)
    %i[nfl_rosters nfl_quarterback_rankings nfl_offensive_line_rankings nfl_receiving_rankings nfl_rushing_rankings
       nfl_defense_rankings nfl_pass_rush_rankings nfl_coverage_rankings nfl_prospects nfl_coaches
       nfl_pass_first_rankings nfl_contracts].each do |key|
      assert_equal %i[nfl_hub], crumbs.chain(key)[0...-1], key
    end
    assert_nil Navigation.page(:nfl_hub).parent, "the NFL Hub is a root"
  end

  # The record pages the initializer draws after the registry: a team's rankings, a
  # season and its weeks under the NFL Hub, a person under People.
  test "[unit] the record crumbs: team rankings and a season under the NFL Hub, a person under People" do
    assert_equal %i[nfl_hub team_rankings], Studio.crumbs.chain(:team_rankings)
    assert_equal %i[nfl_hub season], Studio.crumbs.chain(:season)
    assert_equal %i[nfl_hub season week], Studio.crumbs.chain(:week)
    assert_equal %i[admin_dashboard admin_basement people person], Studio.crumbs.chain(:person)
  end

  # hub-ops-page-headers: the full stack's old "Back to packages" link is its parent, and
  # a source video (drawn after the registry) sits under Videos, as its alt videos' parent.
  test "[unit] the ops crumbs: the full stack under Packages, a video under Videos" do
    crumbs = Navigation.registry.draw_crumbs(Studio::Crumbs.new)
    assert_equal %i[packages], crumbs.chain(:packages_stack)[0...-1]
    assert_nil Navigation.page(:packages).parent, "Packages is a root"
    assert_equal %i[admin_dashboard admin_basement videos video], Studio.crumbs.chain(:video)
    assert_equal %i[deployments mason_heartbeat], crumbs.chain(:heartbeat_all_activities)[0...-1]
  end

  test "[unit] the agent pages keep their own section, out of the DevOps trail" do
    crumbs = Navigation.registry.draw_crumbs(Studio::Crumbs.new)
    %i[pokedex activities_agents agents].each do |key|
      refute_includes crumbs.chain(key), :deployments, key
    end
  end

  # An unknown key raises in test and draws no trail in production, so every key a view
  # hands the crumb trail must be a page in config/navigation.yml.
  CRUMB_KEY_PATTERNS = [
    /studio_crumbs\((?:parent:\s*)?:(\w+)/,
    /current_page:\s*["':](\w+)/,
    /sub_nav:\s*\{\s*nav:\s*:\w+,\s*current:\s*:(\w+)/,
    /page:\s*:(\w+)\s*\}/
  ].freeze

  test "[unit] every crumb key a view names is a page in the registry" do
    keys = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |file|
      source = File.read(file)
      CRUMB_KEY_PATTERNS.flat_map { |pattern| source.scan(pattern).flatten.map { |key| [ key, file ] } }
    end
    assert_operator keys.map(&:first).uniq.size, :>=, 10, "the scan found too few keys to mean anything"
    missing = keys.reject { |key, _| Studio.crumbs.key?(key) }
    assert_empty missing.map { |key, file| "#{key} (#{file.delete_prefix("#{Rails.root}/")})" }
  end

  test "[unit] the app's own Studio.crumbs is drawn at boot" do
    assert Studio.crumbs.key?(:deployments)
    assert_nil Studio.crumbs.fetch(:deployments).parent, "the DevOps board home is a crumb root"
    assert_equal :deployments, Studio.crumbs.fetch(:triage).parent
  end
end
