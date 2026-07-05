require "test_helper"

# Integration tier: the evolution gates and the TaskEvent spine together. Each
# staged transition bakes the mascot that owned THAT event, so the timeline
# shows the line's progression — and history never repaints when the task's
# live mascot evolves later.
class TaskEventEvolutionTest < ActiveSupport::TestCase
  def seed_charmander_line!
    [[4, "charmander", ["charmeleon"]],
     [5, "charmeleon", ["charizard"]],
     [6, "charizard", []]].each do |dex, slug, evolution|
      Pokemon.where(slug: slug).first_or_initialize.update!(
        dex: dex, name: slug.capitalize, slug: slug, generation: 1,
        base: "charmander", evolution: evolution, baby: [],
        avatar_url: "https://example.test/pokemon/#{dex}-#{slug}-cropped.png"
      )
    end
  end

  def snapshot_for(task, to_stage)
    task.task_events.reload.find { |event| event.to_stage == to_stage }&.mascot_snapshot
  end

  test "each transition bakes the mascot form that owned it" do
    seed_charmander_line!
    task = Task.create!(title: "Snapshot evolution walk task")
    task.update_columns(metadata: { "devops" => { "session_id" => "sess-evo",
                                                  "mascot" => "charmander",
                                                  "mascot_session" => "sess-evo" } })
    task = task.reload

    task.build!
    task.submit!
    task.review!
    task.assemble!

    # Build lane: still the base form.
    assert_equal "charmander", snapshot_for(task, "building")["slug"]
    # The submit gate evolved the mascot BEFORE its event baked.
    assert_equal "charmeleon", snapshot_for(task, "submitted")["slug"]
    assert_equal "https://example.test/pokemon/5-charmeleon-cropped.png",
                 snapshot_for(task, "submitted")["avatar"]
    # Deploy lane bakes snapshots too now — reviewed keeps the mid form even
    # though the live mascot is Charizard by the end of the walk.
    assert_equal "charmeleon", snapshot_for(task, "reviewed")["slug"]
    assert_equal "charizard", snapshot_for(task, "assembled")["slug"]
    # The live task mascot finished fully evolved.
    assert_equal "charizard", task.reload.devops["mascot"]
  end

  test "a shiny walk bakes shiny avatars for every form" do
    seed_charmander_line!
    Pokemon.find_by!(slug: "charmeleon").update!(
      shiny_avatar_url: "https://example.test/pokemon/5-charmeleon-shiny-cropped.png"
    )
    task = Task.create!(title: "Shiny snapshot walk task")
    task.update_columns(metadata: { "devops" => { "session_id" => "sess-shiny",
                                                  "mascot" => "charmander",
                                                  "mascot_session" => "sess-shiny",
                                                  "mascot_shiny" => true } })
    task = task.reload

    task.build!
    task.submit!

    submitted = snapshot_for(task, "submitted")
    assert submitted["shiny"]
    assert_equal "https://example.test/pokemon/5-charmeleon-shiny-cropped.png", submitted["avatar"]
  end
end
