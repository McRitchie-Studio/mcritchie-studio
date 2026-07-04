require "test_helper"

# Unit tier: the shiny roll happens ONCE at session-draw time and persists on
# the SessionMascot row — the session's board tasks then adopt the flag (that
# adoption seam is covered in TaskMascotShinyTest).
class SessionMascotShinyTest < ActiveSupport::TestCase
  setup do
    Pokemon.create!(dex: 300, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1)
  end

  test "a lucky draw persists shiny on the session row" do
    Pokemon.stub(:roll_shiny?, true) do
      assert_predicate SessionMascot.for("sess-lucky"), :shiny?
    end
  end

  test "an ordinary draw persists shiny false" do
    Pokemon.stub(:roll_shiny?, false) do
      assert_not SessionMascot.for("sess-plain").shiny?
    end
  end

  test "the roll is stable — rereads never reroll" do
    drawn = Pokemon.stub(:roll_shiny?, true) { SessionMascot.for("sess-stable") }

    Pokemon.stub(:roll_shiny?, false) do
      reread = SessionMascot.for("sess-stable")
      assert_equal drawn.id, reread.id
      assert_predicate reread, :shiny?
    end
  end
end
