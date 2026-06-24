require "test_helper"

# Integration tier (backend shape): db/seeds/52_tasks.rb runs on every deploy, so it
# must be idempotent AND it must seed the board's visual states — a gem release, the
# under-slug stage crew, and a qa-feedback note — so the dashboard renders them in
# dev without hand-seeding (the sparse-seed friction this closes).
class BoardSeedTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("db/seeds/02_agents.rb").to_s
  TASKS  = Rails.root.join("db/seeds/52_tasks.rb").to_s

  def run_seeds
    capture_io do
      load AGENTS # the crew actors the task seed references
      load TASKS
    end
  end

  test "seeds a gem-release card (footer 💎)" do
    run_seeds
    gem = Task.find_by!(title: "Review Turf Monster Tailwind PR")
    assert gem.gem_release?, "the library-shape card must read as a gem release"
    assert gem.devops_url("local"), "and carry the Local footer link"
  end

  test "seeds a building card with the under-slug stage crew" do
    run_seeds
    crew = Task.find_by!(title: "Generate player prop lines")
    actors = crew.task_events.map(&:actor).compact.uniq
    assert_operator actors.size, :>=, 2, "distinct build actors → multiple crew faces under the slug"
  end

  test "seeds a full deploy crew on a shipped gem card" do
    run_seeds
    shipped = Task.find_by!(title: "Deploy Turf Monster v2.1")
    assert_equal "shipped", shipped.stage
    assert shipped.task_events.exists?(to_stage: "shipped"), "the whole journey through shipped"
    assert shipped.gem_release?
  end

  test "seeds a qa-feedback note (the activity box)" do
    run_seeds
    reviewed = Task.find_by!(title: "QA Turf Monster contest flow")
    note = Activity.find_by(task_slug: reviewed.slug, activity_type: "qa_feedback")
    assert note, "a qa-feedback note must back the activity box"
    assert note.description.present?
  end

  test "re-running the seed adds no duplicate crew events or notes (idempotent)" do
    run_seeds
    events = TaskEvent.count
    notes  = Activity.where(activity_type: "qa_feedback").count
    assert_operator events, :>, 0, "the first seed creates crew events"

    run_seeds
    assert_equal events, TaskEvent.count, "re-seed must not duplicate crew events"
    assert_equal notes, Activity.where(activity_type: "qa_feedback").count, "re-seed must not duplicate the note"
  end
end
