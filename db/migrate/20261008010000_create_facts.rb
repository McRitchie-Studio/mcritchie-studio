# A fact: one thing known about a person, a company or an app, with where it
# came from. The value is encrypted by the model (Fact). A new table, so the
# migration takes no lock on anything live.
class CreateFacts < ActiveRecord::Migration[8.1]
  def change
    create_table :facts do |t|
      t.string :slug, null: false
      # person | company | app, validated in the model.
      t.string :subject_type, null: false
      t.string :subject_slug, null: false
      t.string :key, null: false
      # Ciphertext. Null for a pointer: a fact that names only its source.
      t.text :value
      # ordinary | sensitive, validated in the model.
      t.string :sensitivity, null: false, default: "ordinary"
      # knowledge_doc | drive_file, with that document's id and a free note.
      t.string :source_kind, null: false
      t.string :source_ref, null: false
      t.string :source_note
      t.string :recorded_by_session_slug, null: false
      t.datetime :recorded_at, null: false
      t.string :superseded_by_slug
      t.datetime :retired_at
      t.timestamps
    end
    add_index :facts, :slug, unique: true
    add_index :facts, %i[subject_type subject_slug key]
    add_index :facts, :superseded_by_slug
    add_index :facts, :recorded_by_session_slug
    add_foreign_key :facts, :agent_sessions, column: :recorded_by_session_slug, primary_key: :slug, on_update: :cascade
    add_foreign_key :facts, :facts, column: :superseded_by_slug, primary_key: :slug, on_update: :cascade
  end
end
