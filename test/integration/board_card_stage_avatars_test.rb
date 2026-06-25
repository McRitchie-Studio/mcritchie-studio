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

  test "tasks board card splits the build into its stage steps" do
    task = Task.create!(title: "build lane crewed card", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    get tasks_path
    assert_response :success

    # the Build board splits the build into its three steps (designed · building ·
    # submitted) with NO QA spots — a three-column row
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-3", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 2 # designed + building reached; submitted blank
      assert_select "span.text-white", count: 2            # the designer + the builder, each its own column
      assert_select "div[title^='Carl']"                   # designer's own column
      assert_select "div[title^='Shannon']"                # builder's own column
      assert_select "[data-test='crew-live']"              # ticking counter on the current (building) step
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

    # the lane row is a fixed four-column grid (25% each) so the full crew is one
    # solid row in the narrow kanban column, never wrapping
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-4", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 4  # build · review · assembled · shipped
      assert_select "span.text-white", count: 7             # all 7 faces, just stacked
      assert_select "[data-test='crew-duration']", count: 4 # one duration per compartment
    end
  end

  test "crew lanes grow from their column edge on hover (column-aware transform-origin)" do
    # Same full four-lane shipped journey: build · review · assembled · shipped.
    # On card hover each lane's stack scales up 1.5x and its grow DIRECTION is
    # anchored to its column so an enlarged stack never spills off the card's near
    # edge — the leftmost lane grows rightward (origin-left), the last lane grows
    # leftward (origin-right), and the two middle lanes grow from center.
    task = Task.create!(title: "origin crew shipped card", stage: "shipped")
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
      # four filled lanes → leftmost anchors left, the two middles center, the last anchors right
      assert_select ".origin-left",   count: 1
      assert_select ".origin-center", count: 2
      assert_select ".origin-right",  count: 1
      # every lane's stack gets the bigger 1.5x hover bump (was a subtle scale-110)
      assert_select "[class*='scale-150']", count: 4
      # the two edge lanes also slide OUT into the card's side margins on hover
      assert_select "[class*='group-hover:-translate-x-3']", count: 1 # leftmost slides further left
      assert_select "[class*='group-hover:translate-x-3']",  count: 1 # rightmost slides further right
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
