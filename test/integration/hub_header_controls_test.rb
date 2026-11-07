require "test_helper"
require "minitest/mock"

# [component] The hub's page headers on the engine's four kinds of control (Alex McRitchie
# 2026-11-06, studio-engine docs/PAGE_HEADER.md "The four kinds of control"): tabs for
# views of the same data, the Links menu for pages elsewhere, one action, and tools for
# developer-only controls. Task hub-header-controls moved the eight pages that passed the
# deprecated actions_html; these tests hold each page to its kinds and to no free HTML.
class HubHeaderControlsTest < ActionDispatch::IntegrationTest
  ROW = ".page-header".freeze
  KINDS = %w[page-header-menu page-header-action page-header-tools].freeze

  setup { log_in_as(users(:alex)) }

  # Gets the page with the engine's deprecation hook armed, and fails if any header on
  # it still passes actions_html. Every direct child of the control cluster must be one
  # of the engine's own kinds: free HTML would stand there as something else.
  def get_header(path)
    sites = []
    Studio::PageHeader.stub(:warning_enabled?, true) do
      Studio::PageHeader.stub(:deprecate_actions_html, ->(site: nil, **) { sites << site }) do
        get path
      end
    end
    assert_response :success
    assert_empty sites, "#{path} still passes actions_html to studio/page_header"
    css_select("#{ROW} .page-header-actions > *").each do |el|
      assert_includes KINDS, el["class"].to_s.split.first, "#{path}: a header control outside the four kinds"
    end
  end

  def menu_hrefs = css_select("#{ROW} .page-header-menu-list a.page-header-menu-item").map { |a| a["href"] }
  def tab_hrefs = css_select("#{ROW} nav.page-header-tabs a.page-header-tab").map { |a| a["href"] }

  test "[component] no hub view passes actions_html to the engine page header" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].select do |file|
      source = File.read(file)
      source.include?("page_header") && source.match?(/\bactions_html:/)
    end
    assert_empty offenders.map { |f| f.delete_prefix("#{Rails.root}/") }
  end

  test "[component] /deployments: board tabs with Deployments current, the Links menu, one New Task action, the tools" do
    get_header deployments_path

    assert_equal [ tasks_path, triage_path, deployments_path ], tab_hrefs
    assert_select "#{ROW} nav.page-header-tabs[aria-label='Board views'] a[aria-current=page]", 1
    assert_select "#{ROW} nav.page-header-tabs a[href=?][aria-current=page]", deployments_path
    assert_select "#{ROW} .page-header-menu-button", text: "Links"
    assert_equal [ stages_path, review_events_hub_path ], menu_hrefs
    assert_select "#{ROW} a.page-header-action", 1
    assert_select "#{ROW} a.page-header-action[href=?]", new_task_path, text: "New Task"
    assert_select "#{ROW} .page-header-tools [data-test=dev-board-tools]", 1
    assert_select "#{ROW} [data-test=all-stages-toggle]", 0, "All Stages is a board filter, not a header control"
    assert_select "[data-test=board-filter-row] [data-test=all-stages-toggle]", 1
  end

  test "[component] /tasks: board tabs with Tasks current, one New Task action, the tools" do
    get_header tasks_path

    assert_equal [ tasks_path, triage_path, deployments_path ], tab_hrefs
    assert_select "#{ROW} nav.page-header-tabs a[href=?][aria-current=page]", tasks_path
    assert_select "#{ROW} a.page-header-action[href=?]", new_task_path, count: 1
    assert_select "#{ROW} .page-header-menu", 0
    assert_select "#{ROW} .page-header-tools [data-test=dev-deploy-tools]", 1
  end

  test "[component] /triage: board tabs with Triage current; the open count leaves the header" do
    get_header triage_path

    assert_equal [ tasks_path, triage_path, deployments_path ], tab_hrefs
    assert_select "#{ROW} nav.page-header-tabs a[href=?][aria-current=page]", triage_path
    assert_select "#{ROW} .page-header-meta", text: "Findings Inbox"
    assert_select "#{ROW} [data-test=triage-open-count]", 0
    assert_select "[data-test=triage-open-count]", 1
  end

  test "[component] /stages: the boards are pages elsewhere, in the Links menu" do
    get_header stages_path

    assert_select "#{ROW} nav.page-header-tabs", 0
    assert_equal [ tasks_path, triage_path, deployments_path ], menu_hrefs
    assert_select "#{ROW} a.page-header-action", 0
  end

  test "[component] /agents: Dreams and the activities feed in the Links menu" do
    get_header agents_path

    assert_equal [ dreams_path, activities_agents_path ], menu_hrefs
    assert_select "#{ROW} [data-test=agents-dreams-link]", text: "Dreams"
    assert_select "#{ROW} [data-test=agents-activities-link]", text: "Activities feed"
  end

  test "[component] /pokedex: the total is the header's meta, not a control" do
    get_header pokedex_path

    assert_select "#{ROW} .page-header-meta [data-test=pokedex-total]", 1
    assert_select "#{ROW} .page-header-actions", 0
  end

  test "[component] /deployments/all: the dashboard and the model page in the Links menu" do
    Release.create!(slug: "rel-header-controls", branch: "release", state: "shipped")
    get_header all_deployments_path

    assert_includes menu_hrefs, deployments_path
    assert menu_hrefs.any? { |href| href.include?("rel-header-controls") || href.include?("release") },
           "an admin keeps the Model link"
    assert_select "#{ROW} a.page-header-action", 0
  end

  test "[component] /deployments/:slug: the state is meta, All Deployments is in the Links menu" do
    release = Release.create!(slug: "rel-header-controls", branch: "release", state: "shipped")
    get_header deployment_path(release.slug)

    assert_select "#{ROW} .page-header-meta [data-test=release-state]", text: "shipped"
    assert_select "[data-test=release-state-phone].sm\\:hidden [data-test=release-state]", text: "shipped"
    assert_equal [ all_deployments_path ], menu_hrefs
  end
end
