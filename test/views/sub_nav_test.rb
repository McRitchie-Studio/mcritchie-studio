require "test_helper"

# [component] components/_sub_nav: the one section sub-nav, drawn from the
# navigation registry (config/navigation.yml) in the style the registry names,
# and components/_page_header, the standard page title above it.
class SubNavTest < ActionView::TestCase
  def render_nav(nav, current:, admin: true, **locals)
    view.define_singleton_method(:admin?) { admin }
    render partial: "components/sub_nav", locals: { nav: nav, current: current, **locals }
  end

  def hrefs(selector = "nav a") = css_select(selector).map { |link| link["href"] }

  test "[component] board_sections draws the registry's links in order, in one labelled nav" do
    render_nav :board_sections, current: :tasks

    assert_select %(nav[aria-label="Board sections"][data-sub-nav="board_sections"]), 1
    assert_equal [ admin_dashboard_path, stages_path, epics_path, intelligence_path, activities_agents_path, pokedex_path ],
                 hrefs
    assert_equal [ "← Admin dashboard", "Stages", "Epics", "Intelligence", "🎭 Activities", "Pokédex" ],
                 css_select("nav a").map { |link| link.text.strip }
    assert_select "nav a[aria-current]", 0, "the Tasks board has no entry in its own link row"
  end

  test "[component] the current page's link carries aria-current and the active colour" do
    render_nav :board_sections, current: :epics

    current = css_select("nav a[aria-current=page]")
    assert_equal [ epics_path ], current.map { |link| link["href"] }
    assert_includes current.first["class"].split, "text-primary"
    assert_equal "board-link-epics", current.first["data-test"]
    assert_select "nav a.text-muted", 5
  end

  test "[component] the Deploy board swaps Stages for the learning-loop links" do
    render_nav :board_sections, current: :deployments

    assert_not_includes hrefs, stages_path
    assert_equal [ xan_pipeline_path, xan_insights_path, recent_tasks_path ], hrefs.last(3)
    assert_select %(nav a[href="#{xan_insights_path}"]), text: "Insights"
  end

  test "[component] the link row wraps instead of overflowing a phone" do
    render_nav :board_sections, current: :stages

    classes = css_select("nav").first["class"].split
    assert_includes classes, "flex-wrap"
    assert_includes classes, "gap-y-1"
  end

  test "[component] board_views drops the current board and badges the others from the counts" do
    render_nav :board_views, current: :tasks, counts: { building: 3, reviewed: 2, assembled: 0 }

    assert_select %(nav[aria-label="Board views"]), 1
    assert_equal [ triage_path, deployments_path ], hrefs
    assert_select %(a[href="#{deployments_path}"] span[title="2 reviewed"]), text: "2"
    assert_select %(a[href="#{deployments_path}"] span[title="0 assembled"].text-muted), text: "0"
  end

  test "[component] board_views shows Tasks below 1400px only on the Deploy board" do
    render_nav :board_views, current: :deployments, counts: { building: 1 }
    tasks_link = css_select(%(a[href="#{tasks_path}"])).first
    assert_includes tasks_link["class"].split, "min-[1400px]:hidden"
    assert_select %(a[href="#{tasks_path}"] span[title="1 building"]), text: "1"

    render_nav :board_views, current: :stages, counts: {}
    stages_tasks_link = css_select(%(a[href="#{tasks_path}"])).last
    assert_not_includes stages_tasks_link["class"].split, "min-[1400px]:hidden"
    assert_select %(a[href="#{tasks_path}"] span[title="0 building"]), minimum: 1
  end

  test "[component] the heartbeat chips link back to Deployments on every heartbeat page" do
    %i[xan_heartbeat heartbeat_all_activities xan_pipeline].each do |current|
      render_nav :heartbeat, current: current, counts: { insights: 4 }

      link = css_select("a[data-test=hb-nav-deployments]").last
      assert link, "the heartbeat nav must render a Deployments back link on #{current}"
      assert_equal deployments_path, link["href"]
      assert_includes link["class"].to_s.split, "hb-btn", "the back link is an hb-btn chip"
      assert_match "Deployments", link.text
      assert_equal "false", link["data-turbo"]
    end
  end

  test "[component] the heartbeat chips carry the insight tally and mark All Activities current" do
    render_nav :heartbeat, current: :heartbeat_all_activities, counts: { insights: 4 }

    assert_select %(nav[aria-label="Heartbeat"].contents), 1
    assert_select %(a[href="#{xan_insights_path}"] span#hb-insight-count), text: "4"
    assert_select %(a[href="#{xan_insights_path}"]), text: /Insight Bank \(4\)/
    current = css_select("a[aria-current=page]")
    assert_equal [ "hb-nav-all-spans" ], current.map { |link| link["data-test"] }
    assert_includes current.first["class"].split, "primary"
    assert_select %(a[data-test=hb-nav-session][href="#{xan_heartbeat_path}"]), text: /Per-session heartbeat/
  end

  test "[component] the per-session chip shows on All Activities only" do
    render_nav :heartbeat, current: :xan_heartbeat, counts: { insights: 0 }

    assert_select "a[data-test=hb-nav-session]", 0
    assert_select "a[aria-current]", 0
    assert_select "a[data-test=hb-nav-all-spans]:not(.primary)", 1
  end

  # Every sub-nav entry today is an admin page, so a viewer who is not an admin
  # gets no links and no empty nav landmark.
  test "[component] a viewer who is not an admin gets none of the admin entries" do
    %i[board_sections board_views heartbeat].each do |nav|
      render_nav nav, current: :tasks, admin: false
    end

    assert_select "nav", 0
    assert_select "a", 0
  end

  test "[component] an unknown sub-nav key raises instead of rendering nothing" do
    error = assert_raises(ActionView::Template::Error) { render_nav :no_such_nav, current: :tasks }
    assert_kind_of Navigation::Invalid, error.cause
  end

  test "[component] the page header draws the sub-nav, one standard h1, the eyebrow and the description" do
    view.define_singleton_method(:admin?) { true }
    render layout: "components/page_header",
           locals: { title: "Triage", eyebrow: "Findings Inbox", description: "Promote what deserves one.",
                     sub_nav: { nav: :board_sections, current: :epics } } do
      "<span id='beside-title'>controls</span>".html_safe
    end

    assert_select "header[data-test=page-header]", 1
    assert_select "header h1", 1
    assert_select "header h1.text-2xl.font-bold.text-heading", text: "Triage"
    assert_select "header p", text: "Findings Inbox"
    assert_select "header p", text: "Promote what deserves one."
    assert_select "header nav[aria-label='Board sections'] a[aria-current=page]", 1
    assert_select "header #beside-title", text: "controls"
  end

  test "[component] the page header needs only a title" do
    render partial: "components/page_header", locals: { title: "Epics" }

    assert_select "header h1", text: "Epics"
    assert_select "header nav", 0
    assert_select "header p", 0
  end
end
