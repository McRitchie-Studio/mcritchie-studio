require "test_helper"
require_relative "../support/client_cto_fixtures"

# [integration] A newly launched client app's chat (task app-card-stage-labels):
# its only task is the designed build task, so the status card reads Prepping
# and "waiting for a builder" (no launcher is live), never minutes; once a
# launcher pings, the same card reads Prepping with the board's usual wait; and
# the CTO's greeting says the app is in line, never building now.
class AppCardStageLabelsTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentPerson.seed_owner!
    @owner = users(:viewer)
    request = AppRequest.create!(prompt: "A booking site for my groomer", user: @owner)
    @launch = AppLaunch.new(request, subdomain: "pawsome", intake: client_intake).call!
  end

  teardown { AgentMessages::Answerers.reset! }

  def building_pill = "[data-test='devops-stage'][data-stage='building'][data-state='live'][data-count='1']"

  test "[integration] the designed launch task reads Prepping, waiting for a builder, and the greeting says in line" do
    assert_equal "designed", @launch.task.reload.stage
    log_in_as(@owner)
    get chat_application_path("pawsome") # the first visit plays the launch panel (CtoChatsController#play_launch_animation)
    assert_select "[data-test='build-launch']"
    get chat_application_path("pawsome")
    assert_response :success

    # Only a designed task in the lane: the pill reads Prepping, with no count, sub-label or "no builder".
    assert_select "#{building_pill}[data-prepping='true']", text: /\A\s*Prepping\s*,/
    assert_select "#{building_pill} [data-test='devops-stage-count']", 0
    assert_select "#{building_pill} [data-test='devops-stage-sub-label']", 0
    assert_select "#{building_pill} [data-test='devops-stage-eta']", 0
    assert_select "[data-test='devops-task']", text: /Launching Pawsome\s+Prepping · waiting for a builder/
    assert_select "[data-test='devops-stage'][data-state='pending'] [data-test='devops-stage-sub-label']", 0

    page = css_select("body").text
    assert_includes page, "It's in line to be built", "the greeting on the page says in line"
    assert_includes page, "Prepping until a builder starts"
    assert_not_includes page, "building now"
  end

  test "[integration] with a live launcher the card gives the usual wait, and once building it says Building" do
    history = Task.create!(title: "Earlier launch", stage: "designed", priority: 1)
    3.times { |i| TaskEvent.create!(task_slug: history.slug, from_stage: "designed", to_stage: "building", seconds_in_from: 1200, occurred_at: (i + 1).hours.ago) }
    3.times { |i| TaskEvent.create!(task_slug: history.slug, from_stage: "building", to_stage: "submitted", seconds_in_from: 2.hours.to_i, occurred_at: (i + 1).hours.ago) }
    AgentDispatcher.create!(worker_id: "launcher-mac", last_seen_at: 1.minute.ago, souls: [ AppDevopsStages::Eta::LAUNCHER_SOUL ])

    log_in_as(@owner)
    get chat_status_application_path("pawsome")
    assert_select "#{building_pill}[data-prepping='true'] [data-test='devops-stage-eta'][data-eta-kind='left']", text: "~20 min"
    assert_select "[data-test='devops-task']", text: /Prepping · ~20 min left/

    @launch.task.update_columns(stage: "building", started_at: 1.minute.ago)
    get chat_status_application_path("pawsome")
    assert_select "#{building_pill}[data-prepping]", 0, "a task a builder holds makes the lane Building again"
    # One building task (task cto-pill-count-and-links): the pill reads Building, never
    # "Building 1" over "Building"; the wait still shows, and a screen reader still hears the count.
    assert_select "#{building_pill}", text: /\A\s*Building\s*~2 h\s*, 1 task under way, ~2 h left\s*\z/
    assert_select "#{building_pill} [data-test='devops-stage-count']", 0
    assert_select "#{building_pill} [data-test='devops-stage-sub-label']", 0
    assert_select "#{building_pill} [data-test='devops-stage-eta']", text: "~2 h"
  end

  test "[integration] a Building lane of two shows its count, and a sub-label that differs from the label" do
    @launch.task.update_columns(stage: "submitted", started_at: 1.hour.ago, submitted_at: 1.minute.ago)
    Task.create!(title: "Add a gallery", stage: "building", priority: 1, started_at: 1.minute.ago,
                 metadata: { "devops" => { "repositories" => [ "pawsome" ] } })

    log_in_as(@owner)
    get chat_status_application_path("pawsome")
    pill = "[data-test='devops-stage'][data-stage='building'][data-state='live'][data-count='2']"
    assert_select "#{pill} [data-test='devops-stage-count']", text: "2"
    assert_select "#{pill} [data-test='devops-stage-sub-label']", text: "Reviewing"
  end
end
