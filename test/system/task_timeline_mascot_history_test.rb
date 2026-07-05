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
    assert_selector "[data-test='timeline-crew-member'][title^='Grimer']", count: 1
  end

  test "task timeline shows the mascot evolving through the pipeline gates" do
    # Collision-proof against e2e seed leftovers in the shared test DB.
    [[4, "charmander", ["charmeleon"]],
     [5, "charmeleon", ["charizard"]],
     [6, "charizard", []]].each do |dex, slug, evolution|
      Pokemon.where(slug: slug).first_or_initialize.update!(
        dex: dex, name: slug.capitalize, slug: slug, generation: 1,
        base: "charmander", evolution: evolution, baby: []
      )
    end
    SessionMascot.where(session_id: "sess-sys-evolve").first_or_initialize.update!(mascot_slug: "charmander")

    task = Task.create!(title: "system evolution timeline task",
                        metadata: { "devops" => { "session_id" => "sess-sys-evolve" } })
    task.build!
    task.submit!
    task.review!
    task.assemble!

    visit task_path(task.slug)

    assert_selector "[data-test='stage-timeline']"
    # The build lane belongs to the base form; each gate's card wears the form
    # that owned it — the submit stays Charmeleon even after Charizard assembles.
    assert_selector "[data-test='timeline-crew-member'][title^='Charmander']", minimum: 2
    assert_selector "[data-test='timeline-crew-member'][title^='Charmeleon']", minimum: 1
    # The third-stage form (Charizard) is lifted out of the deploy crew into its own
    # "Evolve" reel, so it is no longer a plain timeline crew member.
    assert_selector "[data-test='timeline-block'][data-stage='evolve'] [data-test='timeline-evolution-to']", text: /Charizard/
    assert_no_selector "[data-test='timeline-crew-member'][title^='Charizard']"
  end
end
