# THE TWO COLUMNS A SWIM-LANE BOARD OVER LOOKS NEEDS, AND NOTHING ELSE.
#
# The model pipeline board (/model_pipeline) shows every character model in flight
# across five lanes. The lane a card RENDERS in is DERIVED from facts the look
# already carries — `Appearances::LookReading` — so neither column below is the
# pipeline's state. They are the operator's HAND, which is a different thing:
#
#   stage     the lane the operator dragged this look into. NULL is the common and
#             correct value: "nobody has ever dragged this one", which is not the
#             same as "designed". A NOT NULL default would have made every look on
#             file assert a hand placement nobody made.
#   position  the rank within a lane (studio-engine's Studio::Board::Rankable,
#             100-gapped). NULL sorts last and falls through to created_at DESC, so
#             an un-dragged board still has a stable order.
#
# WHY NOT STORE THE DERIVED LANE TOO. A second home for a fact would need a write
# on every read to stay current — the services that move a look along (a search, a
# verdict, a delivered image) do not know this board exists, and teaching all of
# them to stamp a column is how the column ends up disagreeing with the rows it
# summarises. Deriving costs one grouped query per fact (Appearances::Pipeline) and
# cannot drift.
class AddBoardColumnsToAppearances < ActiveRecord::Migration[8.0]
  def change
    add_column :appearances, :stage, :string
    add_column :appearances, :position, :integer

    # The board's read: live looks ordered by rank within a lane. Partial on
    # `retired_at IS NULL` because the board never renders a retired look, matching
    # the `live` scope every read on this table already goes through.
    add_index :appearances, [:stage, :position],
              name: "index_appearances_board_rank",
              where: "retired_at IS NULL"
  end
end
