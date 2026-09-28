# WHEN THE IDENTITY WAS BOUGHT. `higgsfield_reference_synced_at` moves on every
# status poll, so it cannot date the mint; staleness needs the mint itself.
# NULL on identities minted before this column: their age is unknown, not new.
class AddHiggsfieldReferenceMintedAtToAppearances < ActiveRecord::Migration[8.1]
  def change
    add_column :appearances, :higgsfield_reference_minted_at, :datetime
  end
end
