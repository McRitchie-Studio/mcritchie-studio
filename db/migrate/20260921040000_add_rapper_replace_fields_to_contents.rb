class AddRapperReplaceFieldsToContents < ActiveRecord::Migration[8.1]
  def change
    # The content's own gate state and its cast pointers.
    #
    # The cast is two NAMED slots here rather than a join, deliberately: a
    # rapper-replace piece has exactly one QB and one skill player by
    # definition of its trigger condition. The N-way generality lives on the
    # ARTIFACT (artifact_subjects), which is where a three-person piece — the
    # Carrey/Bush/Burrow case — actually needs it.
    add_column :contents, :colorway, :string
    add_column :contents, :qb_player_slug, :string
    add_column :contents, :skill_player_slug, :string
  end
end
