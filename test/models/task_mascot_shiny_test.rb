require "test_helper"

# Unit tier: a task adopts its session's shiny roll as server-owned
# devops.mascot_shiny (with a ✨ next to the emoji glyphs), and stage-event
# snapshots bake the shiny avatar URL so history keeps the shiny face after the
# mascot recycles to another task.
class TaskMascotShinyTest < ActiveSupport::TestCase
  setup do
    Pokemon.create!(dex: 301, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1,
                    avatar_url: "normal-crop.png", sprite_url: "normal-sprite.png",
                    shiny_avatar_url: "shiny-crop.png", shiny_sprite_url: "shiny-sprite.png")
    Studio::Enumeral.create!(category: "pokemon_type", key: "normal",
                             color: "#A8A77A", metadata: { "emoji" => "🔶" })
  end

  test "a task adopts its session's shiny roll" do
    Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-shiny-adopt") }
    task = Task.create!(title: "Adopts shiny session mascot",
                        metadata: { "devops" => { "session_id" => "sess-shiny-adopt" } })

    assert_predicate task, :mascot_shiny?
    assert_equal "🔶✨", task.devops["mascot_emoji"]
  end

  test "an ordinary session stays non-shiny with no sparkle" do
    Pokemon.stub(:roll_shiny?, false) { SessionMascot.for("sess-plain-adopt") }
    task = Task.create!(title: "Adopts plain session mascot",
                        metadata: { "devops" => { "session_id" => "sess-plain-adopt" } })

    assert_not task.mascot_shiny?
    assert_no_match(/✨/, task.devops["mascot_emoji"].to_s)
  end

  test "a session-less task rolls its own shiny" do
    task = Pokemon.stub(:roll_shiny?, true) { Task.create!(title: "Session less shiny roll") }
    assert_predicate task, :mascot_shiny?
  end

  test "stage event snapshot bakes the shiny avatar" do
    Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-snapshot") }
    task = Task.create!(title: "Snapshot keeps shiny face", stage: "building",
                        metadata: { "devops" => { "session_id" => "sess-snapshot" } })

    snapshot = task.send(:stage_mascot_event_metadata).fetch("mascot")
    assert_equal "shiny-crop.png", snapshot["avatar"]
    assert snapshot["shiny"]
  end

  test "a plain mascot's snapshot carries no shiny key" do
    Pokemon.stub(:roll_shiny?, false) { SessionMascot.for("sess-plain-snapshot") }
    task = Task.create!(title: "Plain snapshot stays plain", stage: "building",
                        metadata: { "devops" => { "session_id" => "sess-plain-snapshot" } })

    snapshot = task.send(:stage_mascot_event_metadata).fetch("mascot")
    assert_equal "normal-crop.png", snapshot["avatar"]
    assert_not snapshot.key?("shiny")
  end
end
