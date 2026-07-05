require "test_helper"

class SessionMascotTest < ActiveSupport::TestCase
  setup do
    @deck = %w[bulbasaur charmander squirtle pikachu snorlax].each_with_index.map do |slug, i|
      Pokemon.create!(dex: 200 + i, name: slug.capitalize, slug: slug, types: %w[normal], generation: 1)
    end
  end

  test "for draws and stores a stable mascot for a new session" do
    sm = SessionMascot.for("sess-1")
    assert sm.persisted?
    assert_equal "sess-1", sm.session_id
    assert_includes @deck.map(&:slug), sm.mascot_slug
  end

  test "for is idempotent — same session keeps the same mascot, one row" do
    first = SessionMascot.for("sess-1").mascot_slug
    assert_equal first, SessionMascot.for("sess-1").mascot_slug
    assert_equal 1, SessionMascot.where(session_id: "sess-1").count
  end

  test "two sessions never share a mascot" do
    refute_equal SessionMascot.for("sess-a").mascot_slug, SessionMascot.for("sess-b").mascot_slug
  end

  test "for reuses a live task's existing mascot for the session" do
    # A legacy task already carrying a session mascot, with no SessionMascot row.
    task = Task.create!(title: "Demo reuse task")
    SessionMascot.delete_all
    task.update_columns(metadata: { "devops" => { "session_id" => "sess-x", "mascot" => "snorlax" } })

    assert_equal "snorlax", SessionMascot.for("sess-x").mascot_slug
  end

  test "for returns nil for a blank session" do
    assert_nil SessionMascot.for("")
    assert_nil SessionMascot.for(nil)
  end

  test "a task created in a session adopts that session's SessionMascot" do
    sm = SessionMascot.for("sess-adopt")
    task = Task.create!(title: "Adopt session mascot",
                        metadata: { "devops" => { "session_id" => "sess-adopt" } })
    assert_equal sm.mascot_slug, task.metadata.dig("devops", "mascot")
  end

  test "pokemon resolves the drawn Pokémon" do
    sm = SessionMascot.for("sess-1")
    assert_equal sm.mascot_slug, sm.pokemon.slug
  end

  test "subagent draws from parent evolution tree excluding the parent mascot" do
    create_bellsprout_tree!
    SessionMascot.create!(session_id: "parent", mascot_slug: "victreebel")

    child = SessionMascot.for("child-1", parent_session_id: "parent")

    assert_includes %w[bellsprout weepinbell], child.mascot_slug
    assert_equal "parent", child.parent_session_id
  end

  test "sibling subagents avoid duplicate available evolutions" do
    create_bellsprout_tree!
    SessionMascot.create!(session_id: "parent", mascot_slug: "victreebel")

    first = SessionMascot.for("child-1", parent_session_id: "parent").mascot_slug
    second = SessionMascot.for("child-2", parent_session_id: "parent").mascot_slug

    assert_equal %w[bellsprout weepinbell], [first, second].sort
  end

  test "single member trees reuse the parent mascot for subagents" do
    SessionMascot.create!(session_id: "parent", mascot_slug: "snorlax")

    child = SessionMascot.for("child-1", parent_session_id: "parent")

    assert_equal "snorlax", child.mascot_slug
    assert_equal "parent", child.parent_session_id
  end

  test "exhausted parent evolution trees fall back to a random tree member" do
    create_bellsprout_tree!
    SessionMascot.create!(session_id: "parent", mascot_slug: "victreebel")
    SessionMascot.create!(session_id: "child-1", parent_session_id: "parent", mascot_slug: "bellsprout")
    SessionMascot.create!(session_id: "child-2", parent_session_id: "parent", mascot_slug: "weepinbell")

    child = SessionMascot.for("child-3", parent_session_id: "parent")

    assert_includes %w[bellsprout weepinbell victreebel], child.mascot_slug
  end

  private

  def create_bellsprout_tree!
    [
      [69, "Bellsprout", "bellsprout", ["weepinbell"]],
      [70, "Weepinbell", "weepinbell", ["victreebel"]],
      [71, "Victreebel", "victreebel", []]
    ].each do |dex, name, slug, evolution|
      Pokemon.find_or_create_by!(slug: slug) do |pokemon|
        pokemon.dex = dex
        pokemon.name = name
        pokemon.types = %w[grass poison]
        pokemon.generation = 1
        pokemon.base = "bellsprout" # families derive from the columns now
        pokemon.evolution = evolution
      end
    end
  end
end
