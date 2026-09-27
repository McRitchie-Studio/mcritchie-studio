require "test_helper"

# [integration] Mascot gender end to end (tasks/pokemon-mascot-gender): a
# SessionMascot draw stamps a gender weighted by the species' gender_rate, the
# session's task adopts it as devops.mascot_gender, a subagent session inherits it
# and draws only from the branches it allows, and the reviewed gate evolves a
# female Nidoran to Nidorina and a male one to Nidorino.
class MascotGenderFlowTest < ActiveSupport::TestCase
  def make(dex, slug, **attrs)
    Pokemon.where(slug: slug).first_or_initialize.tap do |pokemon|
      pokemon.update!({ dex: dex, name: slug.capitalize, slug: slug, types: %w[poison], generation: 1,
                        base: slug, evolution: [], baby: [] }.merge(attrs))
    end
  end

  # The committed seed shape: legacy species rows plus the drawable family row.
  # The family is the ONLY spawnable deck entry here, so every fresh draw is it.
  setup do
    make(29, "nidoran-f", name: "Nidoran♀", gender_rate: 8, evolution: ["nidorina"], sprite_url: "29.png")
    make(32, "nidoran-m", name: "Nidoran♂", gender_rate: 0, evolution: ["nidorino"], sprite_url: "32.png")
    make(30, "nidorina", base: "nidoran", gender_rate: 8, evolution: ["nidoqueen"])
    make(31, "nidoqueen", base: "nidoran", gender_rate: 8)
    make(33, "nidorino", base: "nidoran", gender_rate: 0, evolution: ["nidoking"])
    make(34, "nidoking", base: "nidoran", gender_rate: 0)
    make(29, "nidoran", name: "Nidoran", gender_rate: 4, evolution: %w[nidorina nidorino], sprite_url: "29.png",
                        gender_forms: { "female" => "nidoran-f", "male" => "nidoran-m" },
                        evolution_genders: { "nidorina" => "female", "nidorino" => "male" })
  end

  def build_task_for(session_id)
    Task.create!(title: "Gender flow probe task", stage: "building",
                 metadata: { "devops" => { "session_id" => session_id } })
  end

  def review!(task)
    task.submit!
    task.review!
    task.reload
  end

  test "a session draw stamps a gender and the task adopts it" do
    session_mascot = Pokemon.stub(:gender_die, 0) { SessionMascot.for("sess-female") }
    assert_equal "nidoran", session_mascot.mascot_slug
    assert_equal "female", session_mascot.gender, "die 0 lands under gender_rate 4: female"

    task = build_task_for("sess-female")

    assert_equal "nidoran", task.devops["mascot"]
    assert_equal "female", task.devops["mascot_gender"]
    assert_equal "female", task.mascot_gender
  end

  test "a wiped gender stamp is re-derived from the session on the next save" do
    Pokemon.stub(:gender_die, 0) { SessionMascot.for("sess-wipe") }
    task = build_task_for("sess-wipe")

    metadata = task.metadata.deep_dup
    metadata["devops"].delete("mascot_gender") # a client read-modify-write dropped it
    task.update!(metadata: metadata)

    assert_equal "female", task.reload.devops["mascot_gender"]
  end

  test "the reviewed gate evolves a female Nidoran to Nidorina" do
    Pokemon.stub(:gender_die, 0) { SessionMascot.for("sess-queen") }
    task = build_task_for("sess-queen")

    assert_equal "nidorina", review!(task).devops["mascot"]
    assert_equal "female", task.devops["mascot_gender"], "the gender carries through evolution"
    snapshot = task.task_events.where(to_stage: "reviewed").last.metadata["mascot"]
    assert_equal "female", snapshot["gender"]
  end

  test "the reviewed gate evolves a male Nidoran to Nidorino" do
    session_mascot = Pokemon.stub(:gender_die, 7) { SessionMascot.for("sess-king") }
    assert_equal "male", session_mascot.gender

    task = build_task_for("sess-king")

    assert_equal "nidorino", review!(task).devops["mascot"]
  end

  # Ten runs, because the gate picks a random allowed branch: were the male
  # branch offered, a female would reach Nidorino about half the time.
  test "the gate never offers a branch the gender forbids, across repeated draws" do
    10.times do |run|
      Pokemon.stub(:gender_die, 0) { SessionMascot.for("sess-repeat-#{run}") }
      task = build_task_for("sess-repeat-#{run}")
      assert_equal "nidorina", review!(task).devops["mascot"], "run #{run}"
    end
  end

  test "a subagent session inherits its parent's gender and draws only allowed branches" do
    parent = Pokemon.stub(:gender_die, 0) { SessionMascot.for("sess-parent") }
    assert_equal "female", parent.gender

    children = Array.new(3) do |i|
      # The die would roll male; inheritance must win over a fresh roll.
      Pokemon.stub(:gender_die, 7) { SessionMascot.for("sess-child-#{i}", parent_session_id: "sess-parent") }
    end

    children.each do |child|
      assert_equal "female", child.gender
      assert_includes %w[nidoran nidorina nidoqueen], child.mascot_slug,
                      "a female line never hands a child the Nidorino line"
    end
  end
  test "an inherited gender is kept when the species allows it, and overridden when it cannot" do
    Pokemon.stub(:gender_die, 7) do # a fresh roll would say male
      assert_equal "female", SessionMascot.gender_for("nidoran", "female"), "a mixed species keeps the hint"
      assert_equal "male", SessionMascot.gender_for("nidoran", nil), "no hint: a fresh roll"
    end
    assert_equal "male", SessionMascot.gender_for("nidorino", "female"), "a male-only species cannot be female"
    assert_nil SessionMascot.gender_for("unknown-slug", "female")
  end

  test "a session-less task draws and stamps its own gender" do
    nidorina = Pokemon.find_by!(slug: "nidorina") # female-only, so the roll is forced
    task = Pokemon.stub(:draw, nidorina) { Task.create!(title: "Sessionless gender probe", stage: "building") }

    assert_equal "nidorina", task.devops["mascot"]
    assert_equal "female", task.reload.devops["mascot_gender"]
  end
end
