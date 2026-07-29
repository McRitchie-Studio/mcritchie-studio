require "test_helper"

# [unit] Task's adoption of the studio/board Rankable read-model. The genesis seed
# (set_initial_position — now provided by Studio::Board::Rankable, wired via the
# existing before_create) and reposition! restamp the per-STAGE 100-gap rank the
# board renders by (`position DESC`). This is the model half of the board-primitive
# rebase; the controller reorder action delegates the write to reposition! here.
class TaskBoardRankTest < ActiveSupport::TestCase
  test "the rank is scoped to the stage column" do
    assert_equal :stage, Task.board_zone_attr
  end

  test "set_initial_position seeds max(position)+100 within the stage" do
    base  = Task.create!(title: "rank seed base card", stage: "designed", position: 1_000_000)
    fresh = Task.create!(title: "rank seed fresh card", stage: "designed")
    assert_equal base.position + 100, fresh.position,
                 "a new task lands one 100-gap above its column's max"
  end

  test "set_initial_position never clobbers an explicit rank" do
    task = Task.create!(title: "rank explicit rank card", stage: "designed", position: 42)
    assert_equal 42, task.position
  end

  test "reposition! restamps a column 100-gapped, top id highest" do
    a = Task.create!(title: "reposition rank card a", stage: "designed")
    b = Task.create!(title: "reposition rank card b", stage: "designed")
    c = Task.create!(title: "reposition rank card c", stage: "designed")

    # ids arrive top→bottom; under `position DESC` the top id holds the highest rank.
    Task.reposition!([c.slug, a.slug, b.slug], id_attr: :slug)

    assert_equal 300, c.reload.position, "index 0 → (len - 0) * 100"
    assert_equal 200, a.reload.position, "index 1 → (len - 1) * 100"
    assert_equal 100, b.reload.position, "index 2 → (len - 2) * 100"
  end
end
