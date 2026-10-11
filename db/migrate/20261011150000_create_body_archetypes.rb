# Reusable body-build reference images for the player sheet (task
# player-sheet-uniform-and-build): a look points at one, and the sheet build sends
# its image as a reference for build and proportions only.
#
# A new table plus one nullable column on appearances (no default, no rewrite).
# The three starting rows are inserted WITHOUT images: an image is a paid GPT-5
# generation, bought only on the operator's click on /body-archetypes, never in a
# migration or seed. Re-running the insert is a no-op (ON CONFLICT DO NOTHING).
class CreateBodyArchetypes < ActiveRecord::Migration[8.1]
  ROWS = [
    ["nfl-qb-skill", "Quarterback / skill position",
     "a tall NFL quarterback's athletic build: about 6 ft 3 in and 225 lb, broad padded shoulders, a thick " \
     "muscular back, solid glutes and powerful thighs, athletic and dense rather than lean",
     %w[QB RB FB TE LB K P LS], 1],
    ["nfl-receiver-db", "Receiver / defensive back",
     "a long, lean NFL receiver or defensive back: about 6 ft 1 in and 195 lb, long limbs and a narrow waist, " \
     "broad padded shoulders, explosive muscular thighs and calves",
     %w[WR CB S FS SS DB], 2],
    ["nfl-lineman", "Lineman",
     "a very large NFL lineman: about 6 ft 5 in and 315 lb, massive shoulders and chest, a thick neck, a wide " \
     "heavy trunk, heavy thighs and glutes",
     %w[OT OG T G C OL DT DE DL NT EDGE], 3]
  ].freeze

  def up
    create_table :body_archetypes do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description, null: false
      t.string :position_hints, array: true, null: false, default: []
      t.integer :position, null: false, default: 0
      t.text :image_url
      t.text :image_prompt
      t.datetime :generated_at
      t.bigint :billable_units
      t.string :generation_state
      t.datetime :generation_started_at
      t.text :generation_error
      t.timestamps
    end
    add_index :body_archetypes, :slug, unique: true

    add_column :appearances, :body_archetype_slug, :string
    add_foreign_key :appearances, :body_archetypes, column: :body_archetype_slug, primary_key: :slug,
                                                    on_update: :cascade, on_delete: :nullify

    now = connection.quote(Time.current.utc)
    ROWS.each do |slug, name, description, hints, position|
      array = connection.quote("{#{hints.join(',')}}")
      execute <<~SQL.squish
        INSERT INTO body_archetypes (slug, name, description, position_hints, position, created_at, updated_at)
        VALUES (#{connection.quote(slug)}, #{connection.quote(name)}, #{connection.quote(description)},
                #{array}, #{position}, #{now}, #{now})
        ON CONFLICT (slug) DO NOTHING
      SQL
    end
  end

  def down
    remove_column :appearances, :body_archetype_slug
    drop_table :body_archetypes
  end
end
