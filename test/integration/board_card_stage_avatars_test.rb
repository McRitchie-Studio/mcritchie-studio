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
      assert_select "[data-test='crew-cluster']", count: 1 # build collapses to one stacked circle
      assert_select "span.text-white", count: 2            # designer + builder stacked
      assert_select "div[title^='Carl']"                   # designer
      assert_select "div[title^='Shannon']"                # builder
      assert_select "[data-test='crew-live']"              # ticking counter while building
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

  test "the full crew collapses to four lane compartments (build / review / assembled / shipped)" do
    # A full journey: designer, builder, submitter (build), 2 reviewers, Steffon,
    # Avi = 7 faces — all shown, in four lane compartments.
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

    # the lane row flex-wraps so a full 7-face crew never spills the narrow
    # (min-w-[220px], p-3) kanban column — it bunches to a second row instead
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].flex-wrap", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 4  # build · review · assembled · shipped
      assert_select "span.text-white", count: 7             # all 7 faces, just stacked
      assert_select "[data-test='crew-duration']", count: 4 # one duration per compartment
    end
  end

  test "build-lane card crew wears the task mascot instead of the actor initial" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                    sprite_url: "https://example.test/snorlax-sprite.png")
    task = Task.create!(title: "mascot crew board card", stage: "building",
                        metadata: { "devops" => { "mascot" => "snorlax" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "claude-session")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "claude-session")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "img[src='https://example.test/snorlax-sprite.png']" # the mascot face, not "C"
      assert_select "div[title^='Snorlax']"
    end
  end
end
