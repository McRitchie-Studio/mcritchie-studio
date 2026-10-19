require "test_helper"

# [integration] The app chat's status card reads every open board task for the
# app (task app-card-live-tasks, AppDevopsStages.board_for): the pills light with
# counts, the newest few tasks are listed, an owner reads plain sanitized titles
# with no links or slugs, an admin's titles link to the board, an app with
# nothing moving says so, and the card's live half (cto_chats#status) reloads
# over AppDevopsChannel when a task for the app moves.
class AppCardLiveTasksTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentPerson.seed_owner!
    @alex = users(:alex)
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  teardown { AgentMessages::Answerers.reset! }

  def turf_task(title, stage, repos: [ "turf-monster" ], **attrs)
    Task.create!(title: title, stage: stage, priority: 1, metadata: { "devops" => { "repositories" => repos } }, **attrs)
  end

  def seed_lanes
    release = Release.create!(slug: "rel-card-qa", state: "assembled")
    building = turf_task("Live scores ticker", "building")
    turf_task("Weekly lock email", "submitted")
    turf_task("Contest results page", "assembled", release_slug: release.slug)
    turf_task("Old shipped thing", "shipped", completed_at: 1.day.ago)
    turf_task("Dropped idea", "archived")
    building
  end

  test "[integration] the owner sees lit lanes with counts and plain titles, no links and no slugs" do
    building = seed_lanes
    log_in_as(@owner)
    get chat_application_path("turf-monster")
    assert_response :success

    assert_select "[data-test='devops-stage'][data-stage='building'][data-state='live'][data-count='2'] [data-test='devops-stage-count']", text: "2"
    assert_select "[data-test='devops-stage'][data-stage='releasing'][data-state='live'][data-count='1']"
    assert_select "[data-test='devops-stage'][data-stage='deploying'][data-state='pending'][data-count='0']"
    assert_select "[data-test='devops-idle']", 0
    assert_select "[data-test='devops-task']", 3
    assert_select "[data-test='devops-task']", text: /Live scores ticker\s+Building/
    assert_select "[data-test='devops-task']", text: /Contest results page\s+On QA/
    assert_select "[data-test='devops-task'] a", 0, "an owner gets no links"
    assert_select "[data-test='devops-board'] a[href*='/tasks/']", 0
    assert_not_includes css_select("[data-test='devops-board']").text, building.slug, "no internal slug"
    assert_not_includes response.body, "Old shipped thing"
    assert_not_includes response.body, "Dropped idea"
  end

  test "[integration] an admin's titles link to the board" do
    building = seed_lanes
    log_in_as(@alex)
    get chat_application_path("turf-monster")

    assert_select "[data-test='devops-task-link'][href='#{task_path(building.slug)}']", text: "Live scores ticker"
    assert_select "[data-test='devops-task-link']", 3
    assert_select "turbo-frame#app-devops-turf-monster[target='_top']"
  end

  test "[integration] with nothing in flight the card says so, with no checks" do
    turf_task("Old shipped thing", "shipped", completed_at: 1.day.ago)
    log_in_as(@owner)
    get chat_application_path("turf-monster")

    assert_select "[data-test='devops-idle']", text: "Nothing in progress right now."
    assert_select "[data-test='devops-stage'][data-state='pending']", 3
    assert_select "[data-test='devops-stage'] .devops-stage-mark", 0, "no check implying finished work"
    assert_select "[data-test='devops-tasks']", 0
  end

  test "[integration] the card's live half answers alone, and is 404 for a non-owner like the page" do
    seed_lanes
    log_in_as(@owner)
    get chat_status_application_path("turf-monster")
    assert_response :success
    assert_select "turbo-frame#app-devops-turf-monster [data-test='devops-task']", 3
    assert_select "[data-test='cto-chat-form']", 0

    stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
    log_in_as(stranger)
    get chat_status_application_path("turf-monster")
    assert_response :not_found
    get chat_application_path("turf-monster")
    assert_response :not_found
  end

  test "[integration] the page listens on the app's card stream" do
    log_in_as(@owner)
    get chat_application_path("turf-monster")

    source = css_select("turbo-cable-stream-source[channel='AppDevopsChannel']").sole
    assert_equal "app_devops:turf-monster", AppDevopsChannel.verified_stream_name(source["signed-stream-name"])
  end

  test "[integration] a task moving stage reloads the card for its app; metadata churn does not" do
    task = nil
    assert_broadcasts("app_devops:turf-monster", 1) { task = turf_task("Live scores ticker", "designed") }
    assert_broadcasts("app_devops:turf-monster", 1) { task.update!(stage: "building") }
    assert_broadcasts("app_devops:turf-monster", 0) { task.update!(metadata: task.metadata.deep_merge("devops" => { "risk_tags" => [ "ux" ] })) }

    frame = ActiveSupport::JSON.decode(broadcasts("app_devops:turf-monster").last)
    assert_includes frame, %(target="app-devops-turf-monster")
    assert_includes frame, %(src="#{chat_status_application_path('turf-monster')}")
    assert_not_includes frame, "Live scores ticker", "the shared stream carries no task content"

    log_in_as(@owner)
    get chat_application_path("turf-monster")
    page = css_select("turbo-frame#app-devops-turf-monster").sole
    sent = Nokogiri::HTML5.fragment(frame.match(/<template>(.*)<\/template>/m)[1]).at_css("turbo-frame")
    %w[target class data-test].each { |name| assert_equal page[name], sent[name], "a reload keeps the frame's own #{name}" }
  end

  test "[integration] a chat-opened task reloads its chat's card; a release starting production reloads its members' apps" do
    assert_broadcasts("app_devops:turf-monster", 1) do
      Task.create!(title: "Leaderboard", stage: "designed", priority: 1,
                   metadata: { "devops" => { "repositories" => [ "mcritchie-studio" ],
                                             "source_thread" => "https://mcritchie.studio/applications/turf-monster/chat" } })
    end

    release = Release.create!(slug: "rel-card-prod", state: "assembled")
    turf_task("Contest results page", "assembled", release_slug: release.slug)
    assert_broadcasts("app_devops:turf-monster", 1) { release.update!(prod_deploy_started_at: Time.current) }
  end
end
