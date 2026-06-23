require "test_helper"

# Component tier (ui-only shape): render the real shared _board partial through
# BOTH board controllers and assert the per-stage crew avatars surface on the
# card — for a Build-lane task (/tasks) and a Deploy task (/deployments). The two
# pages render the same app/views/tasks/_board.html.erb, so a single partial
# change lands on both.
class BoardCardStageAvatarsTest < ActionDispatch::IntegrationTest
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @steffon = Agent.create!(name: "Steffon", slug: "steffon")
    @avi     = Agent.create!(name: "Avi", slug: "avi")
  end

  test "tasks board card shows the Build-lane stage-agent avatars" do
    task = Task.create!(title: "build lane crewed card", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "span.text-white", count: 2 # the two build-stage faces
      assert_select "div[title^='Carl']"        # designer
      assert_select "div[title^='Shannon']"     # builder, with its time-in-stage
    end
  end

  test "deployments board card shows reviewer + Steffon + Avi avatars" do
    task = Task.create!(title: "deploy crew shipped card", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "heavy" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "span.text-white", count: 4 # 2 reviewers + Steffon + Avi
      assert_select "div[title^='Steffon']"
      assert_select "div[title^='Avi']"
    end
  end

  test "the +N overflow bubble collapses a crowded crew on the card" do
    # A full journey: designer, builder, submitter, 2 reviewers, Steffon, Avi = 7
    # entries — past the 5-face cap, so a "+2" bubble appears.
    task = Task.create!(title: "crowded crew shipped card", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 7.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 6.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "heavy" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "span.text-white", count: 5 # capped at 5 visible faces
      assert_select "div[title*='Avi'] span", text: "+2", count: 1
    end
  end
end
