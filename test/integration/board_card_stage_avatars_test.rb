require "test_helper"

# Component tier (ui-only shape): render the real shared _board partial through
# BOTH board controllers and assert the per-stage crew now surfaces as the compact
# FOOTER strip — the filled faces only (no grid, no empty-stage slots, no duration
# badges), deduped, capped at the 3 newest with a "+N" overflow pill. For a
# Build-lane task (/tasks) and a Deploy task (/deployments). Both pages render the
# same app/views/tasks/_board.html.erb, so one partial change lands on both.
class BoardCardStageAvatarsTest < ActionDispatch::IntegrationTest
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @steffon = Agent.create!(name: "Steffon", slug: "steffon")
    @avi     = Agent.create!(name: "Avi", slug: "avi")
  end

  test "build-lane card floats the build crew as a footer strip (the old grid is gone)" do
    task = Task.create!(title: "build lane crewed card", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    get tasks_path
    assert_response :success

    # the old per-stage grid + empty-slot placeholders are gone — one floating strip
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-3", count: 0
    assert_select "#card-#{task.slug} [data-test='crew-empty']", count: 0
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']", count: 1
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "div[title^='Carl']"                       # designer
      assert_select "div[title^='Shannon']"                    # builder
      assert_select "[data-test='crew-overflow']", count: 0    # only 2 faces, no +N
    end
  end

  test "deploy card caps the crew at the three newest faces plus a +N pill" do
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

    # 4 distinct souls (shannon, carl, steffon, avi) → 3 shown + a "+1" pill; the
    # newest (Steffon/Avi) stay crisp on the right, the oldest reviewer rolls into +N.
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-overflow']", text: "+1", count: 1
      assert_select "div[title^='Steffon']"
      assert_select "div[title^='Avi']"
    end
  end

  test "build-lane card crew collapses to the task mascot face (deduped)" do
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

    # the two build stages collapse to ONE mascot face (dedup), not two actor bubbles
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "img[src='https://example.test/snorlax-sprite.png']"
      assert_select "div[title^='Snorlax']"
      assert_select "[data-test='crew-overflow']", count: 0
    end
  end
end
