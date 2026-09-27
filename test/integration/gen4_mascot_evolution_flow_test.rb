require "test_helper"

# [integration] A Gen 4-extended mascot end to end (tasks/pokemon-gen-3-and-4):
# over the committed seed, a session draws an Electabuzz, its task adopts it, and
# the two pipeline gates walk the line Gen 4 extended — Electabuzz reviews as
# Electivire, and assembles still Electivire with the gate consumed. The same flow
# takes a Ralts line through a gender-gated Gen 3–4 branch.
class Gen4MascotEvolutionFlowTest < ActiveSupport::TestCase
  setup do
    capture_io { load Rails.root.join("db/seeds/56_pokemon.rb").to_s }
  end

  def draw_session(session_id, slug, die: 7)
    pokemon = Pokemon.find_by!(slug: slug)
    Pokemon.stub(:draw, pokemon) do
      Pokemon.stub(:gender_die, die) { SessionMascot.for(session_id) }
    end
  end

  def build_task_for(session_id)
    Task.create!(title: "Gen 4 evolution flow probe", stage: "building",
                 metadata: { "devops" => { "session_id" => session_id } })
  end

  test "an Electabuzz mascot evolves through both gates to Electivire" do
    assert_equal "electabuzz", draw_session("sess-electabuzz", "electabuzz").mascot_slug
    task = build_task_for("sess-electabuzz")
    assert_equal "electabuzz", task.devops["mascot"]

    task.submit!
    assert_equal "electabuzz", task.reload.devops["mascot"], "submitting spends no gate"

    task.review!
    assert_equal "electivire", task.reload.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]

    task.assemble!
    assert_equal "electivire", task.reload.devops["mascot"], "the line ends at Electivire"
    assert_equal 2, task.devops["mascot_stage"], "the assemble gate is still consumed"
    assert_equal SessionMascot.find_by!(session_id: "sess-electabuzz").mascot_slug, "electabuzz",
                 "the session keeps its own mascot"
  end

  # Ten runs, because the assemble gate picks a random allowed branch: were
  # Gallade offered to a female, she would reach it about half the time.
  test "a female Ralts line never assembles as Gallade" do
    10.times do |run|
      session = draw_session("sess-ralts-#{run}", "ralts", die: 0) # die 0 < rate 4: female
      assert_equal "female", session.gender
      task = build_task_for("sess-ralts-#{run}")
      task.submit!
      task.review!
      assert_equal "kirlia", task.reload.devops["mascot"]
      task.assemble!
      assert_equal "gardevoir", task.reload.devops["mascot"], "run #{run}"
    end
  end
end
