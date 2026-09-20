class AddGameRecapFieldsToContents < ActiveRecord::Migration[8.1]
  def change
    # The finished game this recap is about. NOT a foreign key: `games` lives in
    # turf-monster, and the hub only ever receives a payload about one. The slug
    # is turf-monster's (`<home>-vs-<away>`, plus a pre/post discriminator on the
    # season types that can collide with the regular season).
    add_column :contents, :game_slug, :string

    # The scoreline the recap was composed from, kept verbatim so a later script
    # or asset step can re-read the facts without a second call back to
    # turf-monster. Written once at creation and never recomputed.
    add_column :contents, :game_facts, :jsonb, default: {}, null: false

    # The poll cycle calls `finalise` once per game, but it re-runs freely by
    # design (every scoring event is keyed on ESPN's own play id, so a repeated
    # cycle writes nothing). That safety is what makes a duplicate POST here
    # likely rather than exotic — the same final can arrive on every subsequent
    # cycle. One recap per game per workflow, enforced by the database, because
    # a find_or_create in the controller loses the race against a retry.
    add_index :contents, [:game_slug, :workflow],
              unique: true,
              where: "game_slug IS NOT NULL",
              name: "index_contents_on_game_slug_and_workflow_when_present"
  end
end
