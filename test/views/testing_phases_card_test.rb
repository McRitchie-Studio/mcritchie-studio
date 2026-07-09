require "test_helper"

# The task-page testing-phases card (_testing_phases.html.erb): owner avatars per
# phase tile + the primary/light review lanes that break out the overall Review
# duration (feature: phase-strip-lane-avatars). Rendered in isolation with
# explicit locals so the card's sparse-first wiring is pinned surface-first.
class TestingPhasesCardTest < ActionView::TestCase
  include ApplicationHelper
  include StageAgentsHelper

  setup do
    Pokemon.create!(dex: 9002, name: "Pikachu", slug: "pikachu", sprite_url: "/pokemon/pikachu.png")
    Agent.create!(name: "Avi", slug: "avi", avatar: "/agents/avi.png")
    Agent.create!(name: "Shannon", slug: "shannon", avatar: "/agents/shannon.png")
    Agent.create!(name: "Carl", slug: "carl", avatar: "/agents/carl.png")
    @task = Task.create!(title: "phases card task", stage: "submitted")
    @task.update_columns(metadata: { "devops" => { "mascot" => "pikachu" } }) # rubocop:disable Rails/SkipsModelValidations

    @phases = { "phases" => {
      "build"               => { "status" => "completed", "seconds" => 600 },
      "local_certification" => { "status" => "missing" },
      "ci"                  => { "status" => "missing" },
      "review"              => { "status" => "in_progress", "seconds" => 300 }
    } }

    now = Time.zone.parse("2026-07-08 14:00:00")
    @gate_runs = {
      "g2a_primary" => GateRun.new(key: "g2a_primary", actor: "shannon",
                                   started_at: now, finished_at: now + 12.minutes, success: true),
      "g2b_light"   => GateRun.new(key: "g2b_light", actor: "carl",
                                   started_at: now, finished_at: now + 6.minutes, success: true)
    }
  end

  test "[component] card tiles wear owner avatars and the review lanes carry souls + durations" do
    render partial: "tasks/testing_phases",
           locals: { testing_phases: @phases, task: @task, task_gate_runs: @gate_runs }

    # Owner avatars: mascot fronts Build (a machine phase), Avi fronts Review.
    assert_select "img[src=?]", "/pokemon/pikachu.png", minimum: 1
    assert_select "img[src=?]", "/agents/avi.png", count: 1

    # Review lanes break the Review duration into its two seats.
    assert_select "[data-test=?]", "testing-review-lanes", count: 1
    assert_select "[data-test=?]", "testing-review-lane", count: 2
    assert_select "[data-test='testing-review-lane'] img[src=?]", "/agents/shannon.png", count: 1
    assert_select "[data-test='testing-review-lane'] img[src=?]", "/agents/carl.png", count: 1
    assert_select "[data-test='testing-review-lane']", text: /Primary/
    assert_select "[data-test='testing-review-lane']", text: /Light/
    assert_match(/12m/, rendered, "the primary lane shows its measured duration")
    assert_match(/6m/, rendered, "the light lane shows its measured duration")
  end

  test "[component] the card stays sparse when there is no mascot and no review runs" do
    # No mascot, no Avi, no reviewer souls, no review runs → every owner is
    # unresolvable, so the card degrades to the bare four phase tiles.
    @task.update_columns(metadata: {}) # rubocop:disable Rails/SkipsModelValidations
    Agent.delete_all
    Pokemon.delete_all

    render partial: "tasks/testing_phases",
           locals: { testing_phases: @phases, task: @task, task_gate_runs: {} }

    assert_select "[data-test=?]", "phase-tile-avatar", count: 0, message: "no owners resolve → no faces"
    assert_select "[data-test=?]", "testing-review-lanes", count: 0, message: "no review runs → no lanes"
    assert_select "p.label-upper", text: "Review", count: 1, message: "the overall Review tile stays visible"
  end
end
