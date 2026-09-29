# The character-sheet build state for one look (building / done / failed). On the
# look rather than its own table: one build at a time per look is the rule, and the
# artifacts already are the history. All nullable: no backfill.
class AddSheetBuildToAppearances < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :sheet_build_state, :string
    add_column :appearances, :sheet_build_started_at, :datetime
    add_column :appearances, :sheet_build_finished_at, :datetime
    add_column :appearances, :sheet_build_error, :text
  end
end
