require "application_system_test_case"

# E2E happy path: a task page opened after a rework handoff preserves the original
# build mascot on historical timeline cards while the new builder owns the live
# build card.
class TaskTimelineMascotHistoryTest < ApplicationSystemTestCase
  test "task timeline shows the blocking agent" do
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "system blocked actor task", stage: "submitted")

    # A block is a `building` attribute now — the blocker is the blocked_by column.
    task.block!(by: "shannon", kind: "rework")

    visit task_path(task.slug)

    assert_selector "[data-test='stage-timeline']"
    assert_selector "[data-test='timeline-block'][data-stage='blocked'] [data-test='timeline-crew-member'][title^='Shannon']"
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
    # Rework: block (a building attribute), resubmit, then a NEW session rebuilds —
    # that fresh building transition swaps the current mascot to grimer.
    task.block!(by: "avi", kind: "rework")
    task.update!(stage: "submitted")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "session_id" => "sess-rework" }))
    task.build!

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
    # Both gates are on the accepting side of the submit seam now, so the WHOLE
    # build lane — designed, building AND the submit hand-off — belongs to the base
    # form. History stays rewritten-proof: those cards keep Charmander even after
    # Charizard assembles.
    assert_selector "[data-test='timeline-crew-member'][title^='Charmander']", minimum: 3
    # The deploy cards carry their human owners, so the two evolved forms live in
    # the Evolve reel: Charmeleon (what the review gate made) → Charizard.
    assert_selector "[data-test='timeline-block'][data-stage='evolve'] [data-test='timeline-evolution-from']", text: /Charmeleon/
    assert_selector "[data-test='timeline-block'][data-stage='evolve'] [data-test='timeline-evolution-to']", text: /Charizard/
    assert_no_selector "[data-test='timeline-crew-member'][title^='Charizard']"
    assert_no_selector "[data-test='timeline-crew-member'][title^='Charmeleon']"
  end
end
