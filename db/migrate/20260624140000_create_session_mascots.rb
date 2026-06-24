class CreateSessionMascots < ActiveRecord::Migration[7.2]
  def change
    create_table :session_mascots do |t|
      # One Pokémon per agent session, drawn eagerly (at session start) so the
      # status line shows it in seconds instead of only once the first task lands.
      t.string :session_id,  null: false
      t.string :mascot_slug, null: false

      t.timestamps
    end

    add_index :session_mascots, :session_id, unique: true
  end
end
