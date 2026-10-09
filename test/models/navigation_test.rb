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

    assert_equal "/tasks", paths.fetch("tasks")
    assert_equal "/games/2026", paths.fetch("games_season")
    assert_equal "/error_logs", paths.fetch("error_logs")
    assert paths.values.all? { |path| path.start_with?("/") }
  end

  test "[unit] an audience other than public or admin does not load" do
    [ nil, "", "Public", "everyone", "signed_in", true ].each do |audience|
      data = minimal(pages: { "tasks" => { "page" => "tasks#index", "audience" => audience, "label" => "Tasks" } })
      error = assert_raises(Navigation::Invalid, "audience #{audience.inspect} must be refused") { Navigation.new(data) }
      assert_match "audience must be public or admin", error.message
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

  # The two dashboards point at different pages, so they carry different names.
  test "[unit] no two sidebar entries share a label" do
    labels = (Navigation.sidebar(:admin) + Navigation.sidebar(:general)).flat_map(&:pages).map(&:label)

    assert_equal labels.uniq, labels
    assert_equal "Studio dashboard", Navigation.page(:dashboard).label
    assert_equal "Admin dashboard", Navigation.page(:admin_dashboard).label
    assert_not_equal Navigation.page(:dashboard).action_id, Navigation.page(:admin_dashboard).action_id
  end
end
