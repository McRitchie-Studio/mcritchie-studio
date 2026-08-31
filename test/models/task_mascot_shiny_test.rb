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

  # The wipe these guard: mascot_shiny/color/emoji/stage are server-owned (absent
  # from DEVOPS_KEYS), and a client that REBUILDS the hash from the whitelist — what
  # `bin/task`'s read-modify-write does, and what this helper reproduces — writes a
  # devops hash carrying only whitelisted keys. (The v1 devops PATCH itself merges
  # since api-devops-patch-replaces, and being absent from DEVOPS_KEYS is what makes
  # these four survive it; this echo is the door still open.) Before sync_mascot_display
  # the stamps died there and every later event snapshot baked the NON-shiny face —
  # the board card's second crew slot lost its sprite and its ✨.
  def client_patch(task, devops)
    task.update!(metadata: { "devops" => Task.normalize_devops_metadata(task.devops.merge(devops)) })
    task.reload
  end

  test "a client devops write cannot wipe the shiny stamp" do
    Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-shiny-wipe") }
    task = Task.create!(title: "Survives the devops wipe",
                        metadata: { "devops" => { "session_id" => "sess-shiny-wipe" } })

    client_patch(task, "branch" => "feat/survives-the-devops-wipe")

    assert_predicate task, :mascot_shiny?
    assert_equal "🔶✨", task.devops["mascot_emoji"]
    assert_equal "#A8A77A", task.devops["mascot_color"]
    assert_equal "feat/survives-the-devops-wipe", task.devops["branch"]
  end

  test "the snapshot baked after a client write keeps the shiny face" do
    Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-shiny-late-snapshot") }
    task = Task.create!(title: "Late snapshot stays shiny",
                        metadata: { "devops" => { "session_id" => "sess-shiny-late-snapshot" } })
    client_patch(task, "branch" => "feat/late-snapshot-stays-shiny")

    task.update!(stage: "building")
    snapshot = task.task_events.find_by(to_stage: "building").mascot_snapshot

    assert_equal "shiny-crop.png", snapshot["avatar"]
    assert snapshot["shiny"]
  end

  test "a wiped record heals from its session on the next save" do
    Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-shiny-heal") }
    task = Task.create!(title: "Heals a wiped shiny stamp",
                        metadata: { "devops" => { "session_id" => "sess-shiny-heal" } })
    # The damage 12 production tasks already carry: stamps gone, mascot intact.
    wiped = task.devops.except("mascot_shiny", "mascot_color", "mascot_emoji")
    task.update_column(:metadata, { "devops" => wiped }) # rubocop:disable Rails/SkipsModelValidations
    assert_not task.reload.mascot_shiny?

    task.update!(priority: 2) # any save at all, not a mascot-shaped one

    assert_predicate task.reload, :mascot_shiny?
    assert_equal "🔶✨", task.devops["mascot_emoji"]
  end

  test "a session-less task's own roll survives a client write" do
    task = Pokemon.stub(:roll_shiny?, true) { Task.create!(title: "Session less roll survives") }

    client_patch(task, "branch" => "feat/session-less-roll-survives")

    assert_predicate task, :mascot_shiny?
  end

  test "an ordinary mascot stays non-shiny through a client write" do
    Pokemon.stub(:roll_shiny?, false) { SessionMascot.for("sess-plain-wipe") }
    task = Task.create!(title: "Plain mascot stays plain",
                        metadata: { "devops" => { "session_id" => "sess-plain-wipe" } })

    client_patch(task, "branch" => "feat/plain-mascot-stays-plain")

    assert_not task.mascot_shiny?
    assert_no_match(/✨/, task.devops["mascot_emoji"].to_s)
  end
end
