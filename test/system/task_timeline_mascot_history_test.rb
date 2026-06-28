require "application_system_test_case"

# E2E happy path: a task page opened after a rework handoff preserves the original
# build mascot on historical timeline cards while the new builder owns the live
# build card.
class TaskTimelineMascotHistoryTest < ApplicationSystemTestCase
  test "task timeline shows the blocking agent" do
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "system blocked actor task", stage: "submitted")

    Current.task_event_actor = "shannon"
    task.block!
    Current.reset

    visit task_path(task.slug)

    assert_selector "[data-test='stage-timeline']"
    assert_selector "[data-test='timeline-block'][data-stage='blocked'] [data-test='timeline-crew-member'][title^='Shannon']"
  ensure
    Current.reset
  end

  test "task timeline preserves historical mascots after a rework handoff" do
    Pokemon.create!(dex: 87, name: "Dewgong", slug: "dewgong", generation: 1)
    Pokemon.create!(dex: 88, name: "Grimer", slug: "grimer", generation: 1)
    SessionMascot.create!(session_id: "sess-design", mascot_slug: "dewgong")
    SessionMascot.create!(session_id: "sess-rework", mascot_slug: "grimer")

    task = Task.create!(title: "system mascot history task",
                        metadata: { "devops" => { "session_id" => "sess-design" } })
    task.build!
    task.submit!
    task.block!
    task.update!(stage: "building",
                 metadata: task.metadata.deep_merge("devops" => { "session_id" => "sess-rework" }))

    visit task_path(task.slug)

    assert_selector "[data-test='stage-timeline']"
    assert_selector "[data-test='timeline-crew-member'][title^='Dewgong']", minimum: 3
    assert_selector "[data-test='timeline-crew-member'][title^='Grimer']", minimum: 2
  end
end
