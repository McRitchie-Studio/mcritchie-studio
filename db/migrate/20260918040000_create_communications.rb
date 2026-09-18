# The communications record: who said what, and what was asked.
#
# ONE table, TWO record kinds, because they are the same thing at different
# resolutions and splitting them into two tables would mean joining them back
# together on every read:
#
#   general — the raw stream. Transcripts, texts, messages, calls. High volume,
#             low structure; it gets filed and you move past it.
#   ask     — a specific request that needs work, and the reason this exists.
#             `processing` is unbounded text so the reasoning has room to
#             breathe; `key_points` is capped per entry so the conclusion stays
#             findable. The ask columns are null for a `general` row.
class CreateCommunications < ActiveRecord::Migration[8.1]
  def change
    create_table :communications do |t|
      t.string :kind, null: false
      t.string :entity
      t.string :channel, null: false
      t.string :external_id
      t.string :thread_key
      t.datetime :occurred_at
      t.string :direction
      t.jsonb :participants, null: false, default: []
      t.string :subject
      t.text :body_text
      t.text :summary
      t.string :source_ref
      t.jsonb :tags, null: false, default: []
      t.jsonb :access, null: false, default: {}
      t.boolean :privileged, null: false, default: false

      # --- kind = "ask" only ---------------------------------------------------
      t.text :ask_text
      # Unbounded ON PURPOSE. The working, the reasoning, the dead ends.
      t.text :processing
      t.jsonb :key_points, null: false, default: []
      t.string :status
      t.string :deliverable_url
      t.datetime :due_at
      t.string :owner

      t.timestamps
    end

    # IDEMPOTENT RE-INGEST. A second pull of the same Gmail message or Fathom
    # transcript must not create a second row.
    #
    # Postgres treats NULLs as DISTINCT in a unique index, so any number of rows
    # may carry a null external_id. That is deliberate rather than an oversight:
    # a hand-created ask has no external id, and several of them must be able to
    # coexist on the same channel. Pinned by a test, because it reads like a hole.
    add_index :communications, [ :channel, :external_id ], unique: true

    # The board query: one entity's asks by state.
    add_index :communications, [ :entity, :kind, :status ]
    # Everything on one conversation, across channels.
    add_index :communications, :thread_key
    # The stream, newest first.
    add_index :communications, :occurred_at
  end
end
