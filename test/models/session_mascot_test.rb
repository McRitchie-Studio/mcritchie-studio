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
end
