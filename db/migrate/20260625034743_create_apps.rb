class CreateApps < ActiveRecord::Migration[7.2]
  # The canonical app registry — the source of truth for each managed app's
  # display name and STATUS-LINE IDENTITY (color + emoji). bin/statusline tints
  # the app slug with `color`; the marker/context carry it (resolved server-side,
  # exactly like the Pokémon mascot's signature color). Previously this lived only
  # as the APP_OVERRIDES hash in bin/agent-worktree + docs/app-registry.md.
  def change
    create_table :apps do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :color   # #RRGGBB — the app's status-line tint (e.g. MS lavender)
      t.string :emoji   # optional glyph for the board UI / future status-line use
      t.text   :description
      t.integer :position, default: 0
      t.string :status, default: "active"
      t.timestamps
    end
    add_index :apps, :slug, unique: true
  end
end
