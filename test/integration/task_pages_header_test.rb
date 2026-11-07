require "test_helper"
require "minitest/mock"
require_relative "../support/agent_message_fixtures"

# [component] The task, agent and content detail pages on the engine page header (task
# task-pages-standard-header, Alex McRitchie 2026-11-07 "clean up the DOM and UI"). Each
# page was a custom header: a back-link row over a title card (style S2) or a text back
# link over a bare title (style S3), most with the title as an h2. Each now renders
# studio/page_header with a crumb trail where the back link stood, its title as the
# page's one h1, and its controls in the engine's four kinds (studio-engine
# docs/PAGE_HEADER.md): never actions_html.
class TaskPagesHeaderTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  ROW = ".page-header".freeze
  KINDS = %w[page-header-menu page-header-action page-header-tools].freeze

  setup do
    log_in_as(users(:alex))
    @task = tasks(:in_progress_task)
    @task.update!(agent_slug: agents(:alex_agent).slug, priority: 2)
    @content = contents(:idea_content)
    @news = news(:new_article)
    @agent = agents(:alex_agent)
    @broadcast = Broadcast.create!(slug: "header-test", subject: "Header test", template_key: "cyvasse_is_back",
                                   target_list: "cyvasse-legacy")
    @message = agent_message!(soul: "avi")
    @team = Team.create!(name: "Header Gridiron", sport: "football", league: "nfl", emoji: "🏈", color_primary: "#123456")
    DepthChart.create!(team_slug: @team.slug, slug: "#{@team.slug}-depth")
    Task.create!(title: "Header epic task", stage: "building", epic_slug: "header-epic")
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
  def menu_hrefs = css_select("#{ROW} .page-header-menu-list a.page-header-menu-item").map { |a| a["href"] }

  # Each page: its address, its title, the crumbs it must carry (the old back link's
  # target among them) and, where it has one, its action.
  def pages
    [
      { path: task_path(@task.slug), title: @task.title,
        crumbs: [ admin_dashboard_path, deployments_path ], action: edit_task_path(@task.slug),
        menu: [ task_sizing_path(@task), agent_path(@task.agent_slug) ] },
      { path: review_events_task_path(@task.slug), title: "Review activity",
        crumbs: [ deployments_path, task_path(@task.slug) ], menu: [ review_events_hub_path ] },
      { path: review_events_hub_path, title: "Review Process Hub", crumbs: [ deployments_path ], menu: [ tasks_path ] },
      { path: new_task_path, title: "New Task", crumbs: [ deployments_path ] },
      { path: edit_task_path(@task.slug), title: "Edit Task", crumbs: [ deployments_path, task_path(@task.slug) ] },
      { path: sop_path, title: "DevOps SOP", crumbs: [ deployments_path, stages_path ] },
      { path: task_sizing_path(@task), title: @task.title, crumbs: [ task_path(@task.slug) ] },
      { path: content_path(@content.slug), title: @content.title, crumbs: [ contents_path ],
        action: edit_content_path(@content.slug) },
      { path: new_content_path, title: "New Content Idea", crumbs: [ contents_path ] },
      { path: edit_content_path(@content.slug), title: "Edit Content", crumbs: [ contents_path, content_path(@content.slug) ] },
      { path: news_path(@news.slug), title: @news.title, crumbs: [ news_index_path ], action: edit_news_path(@news.slug) },
      { path: new_news_path, title: "New Article", crumbs: [ news_index_path ] },
      { path: edit_news_path(@news.slug), title: "Edit Article", crumbs: [ news_index_path, news_path(@news.slug) ] },
      { path: workflow_news_index_path, title: "News Workflow", crumbs: [ news_index_path ] },
      { path: agent_path(@agent.slug), title: @agent.name, crumbs: [ agents_path ], menu: [ deployments_path ] },
      { path: doc_path("agents/steffon/HEARTBEAT"), title: "Steffon Heartbeat", crumbs: [ docs_path ] },
      { path: dreams_path, title: "Dreams", crumbs: [ agents_path ] },
      { path: admin_agent_message_path(@message), title: "Message #{@message.id}", crumbs: [ admin_agent_messages_path ] },
      { path: admin_model_pricing_model_path("claude-opus-4-8"), title: nil, crumbs: [ admin_model_pricing_path ] },
      { path: broadcast_queue_path(@broadcast), title: "Queue", crumbs: [ broadcasts_path, edit_broadcast_path(@broadcast) ] },
      { path: edit_broadcast_path(@broadcast), title: "Edit broadcast", crumbs: [ broadcasts_path ] },
      { path: cyvasse_four_scoreboard_path, title: "Cyvasse four-style test", crumbs: [ broadcast_analytics_path ] },
      { path: team_depth_chart_path(@team.slug), title: "🏈 Header Gridiron — Depth Chart", crumbs: [ nfl_rosters_path ] },
      { path: epic_path("header-epic"), title: "header-epic", crumbs: [ deployments_path, epics_path ],
        menu: [ tasks_path(epic: "header-epic"), deployments_path(epic: "header-epic") ] }
    ]
  end

  test "[component] each task page renders studio/page_header with crumbs and exactly one h1" do
    pages.each do |page|
      get_header page[:path]

      assert_select ROW, { count: 1 }, "#{page[:path]}: one page header"
      assert_select "h1", { count: 1 }, "#{page[:path]}: one h1 on the page"
      assert_select "#{ROW} h1.page-header-title", { count: 1 }, "#{page[:path]}: the h1 is the header's title"
      assert_select "#{ROW} h1.page-header-title", { text: page[:title] }, "#{page[:path]}: the title" if page[:title]
      assert_select "#{ROW} nav.page-header-crumbs[aria-label=Breadcrumb]", { count: 1 }, "#{page[:path]}: a crumb trail"
      assert_select "#{ROW} a.page-header-parent", { count: 1 }, "#{page[:path]}: the phone's parent link"
      page[:crumbs].each do |href|
        assert_includes crumb_hrefs, href, "#{page[:path]}: the trail reaches #{href}"
      end
      assert_equal page[:crumbs].last, crumb_hrefs.last, "#{page[:path]}: the old back link is the trail's last crumb"
      if page[:action]
        assert_select "#{ROW} a.page-header-action", { count: 1 }, "#{page[:path]}: one action"
        assert_select "#{ROW} a.page-header-action[href=?]", page[:action]
      end
      (page[:menu] || []).each do |href|
        assert_includes menu_hrefs, href, "#{page[:path]}: the Links menu reaches #{href}"
      end
    end
  end

  test "[component] /tasks/:slug: Edit is the action, Sizing and the agent in the menu, stage and slug as meta with a phone copy" do
    get_header task_path(@task.slug)

    assert_select "#{ROW} a.page-header-action[data-test=task-edit]", text: "Edit"
    assert_select "#{ROW} .page-header-menu-button", text: "Links"
    assert_select "#{ROW} .page-header-meta [data-test=task-slug]", text: @task.slug
    assert_select "#{ROW} .page-header-meta [data-test=task-priority]", text: "Priority 2"
    assert_select "[data-test=task-meta-phone].sm\\:hidden [data-test=task-slug]", text: @task.slug
    assert_select "#{ROW} .page-header-crumb-current", text: "Task"
    assert_select "a", { text: /All Tasks/, count: 0 }, "the back link is the crumb trail now"
  end

  test "[component] /broadcasts/:id/edit and its queue: Editor and Queue are tabs, Copy HTML stays on the page" do
    get_header edit_broadcast_path(@broadcast)
    assert_select "#{ROW} nav.page-header-tabs[aria-label=Broadcast] a[aria-current=page][href=?]", edit_broadcast_path(@broadcast)
    assert_select "#{ROW} nav.page-header-tabs a[href=?]", broadcast_queue_path(@broadcast)
    assert_select "#{ROW} #copy-html-btn", 0
    assert_select "#copy-html-btn", 1
    # A new tab, so the editor's unsaved edits survive; the engine menu takes no target.
    assert_select "#{ROW} [data-test=broadcast-link-preview]", 0
    assert_select "a[data-test=broadcast-link-preview][target=_blank][href=?]", preview_broadcast_path(@broadcast)

    get_header broadcast_queue_path(@broadcast)
    assert_select "#{ROW} nav.page-header-tabs a[aria-current=page][href=?]", broadcast_queue_path(@broadcast)
    assert_select "#{ROW} nav.page-header-tabs a[href=?]", edit_broadcast_path(@broadcast), text: "Editor"
  end

  test "[component] /contents/:slug: the lineup Preview stays on the page and opens a new tab" do
    content = Content.create!(title: "Header lineup", stage: "idea", workflow: "starter_post_x", team_slug: @team.slug)
    get_header content_path(content.slug)
    assert_select "#{ROW} [data-test=content-link-preview]", 0
    assert_select "[data-test=content-workflow-actions] a[data-test=content-link-preview][target=_blank][href=?]",
                  team_lineup_graphic_path(@team.slug)
  end

  test "[component] /docs/:path lifts the doc's first h1 into the header and keeps one h1" do
    get_header doc_path("agents/steffon/HEARTBEAT")
    assert_select ".prose-themed h1", 0
    assert_select "#{ROW} [data-test=doc-path]", text: "agents/steffon/HEARTBEAT.md"
  end

  test "[component] the agent message's status stays one #am-status, with a phone copy" do
    get_header admin_agent_message_path(@message)
    assert_select "#{ROW} .page-header-meta #am-status", 1
    assert_select "#am-status", 1
    assert_select "[data-test=am-status-phone]", text: @message.status
  end
end
