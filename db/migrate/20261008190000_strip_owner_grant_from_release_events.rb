# A data migration: removes the reserved `owner_grant` key from the metadata of
# every stored release event. The key names who approved a production ship, and it
# counts only when signed (Release::LaneLease.owner_grant); a row stored by code
# with no strip can carry an unsigned copy. One UPDATE, matching rows only, so it
# is safe on a table being written and a second run changes nothing. Every other
# metadata key, and every other column, is left as it is.
class StripOwnerGrantFromReleaseEvents < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE release_events
         SET metadata = metadata - 'owner_grant'
       WHERE jsonb_exists(metadata, 'owner_grant')
    SQL
  end

  # The removed markers are not restored: they carry no signature, so no reader
  # counts them.
  def down; end
end
