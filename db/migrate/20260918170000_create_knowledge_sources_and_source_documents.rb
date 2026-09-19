# A METADATA index over external knowledge layers — never a copy of them.
#
# The operator's rule (2026-09-18): a layer such as Google Drive already IS the
# knowledge; duplicating its bytes buys nothing and costs a second place to keep
# private. So this records only that a document exists, where it lives, and
# enough about its state to know when it has changed. More layers follow —
# Egnyte, call transcripts — so nothing here is Drive-shaped except the data in
# the `kind` and `metadata` columns.
class CreateKnowledgeSourcesAndSourceDocuments < ActiveRecord::Migration[8.1]
  def change
    # One row per layer INSTANCE — e.g. each shared Drive folder we index.
    create_table :knowledge_sources do |t|
      t.string :kind, null: false                 # google_drive | egnyte | transcripts
      t.string :name, null: false
      t.string :external_root_id, null: false     # the folder / space / collection walked
      t.string :entity
      # Default per-agent access for documents found here (same levels as the
      # knowledge layer: full | aware | none). Inherited once, at create.
      t.jsonb :access, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.datetime :last_walked_at                  # last walk that COMPLETED
      t.string :last_walk_error
      t.timestamps
    end
    add_index :knowledge_sources, [ :kind, :external_root_id ], unique: true

    # One row per external document. No content column, by design.
    create_table :source_documents do |t|
      t.references :knowledge_source, null: false, foreign_key: true
      t.string :external_id, null: false
      t.string :title
      t.string :mime_type
      t.string :web_url
      t.string :owner_email
      t.bigint :byte_size
      # The layer's own change signal. For Drive this is File#version, which
      # rises on every server-side change — including native Google Docs, where
      # md5 and head revision are absent.
      t.string :remote_version
      t.datetime :remote_modified_at
      t.string :checksum
      t.jsonb :parents, null: false, default: []
      t.string :status, null: false, default: "active"   # active | missing
      t.datetime :last_seen_at
      # What the index last acted on. A document needs indexing when these
      # disagree with the remote_* columns above.
      t.string :indexed_version
      t.datetime :last_indexed_at
      # Triage fields — written once at create, never overwritten by a walk.
      t.string :entity
      t.jsonb :access, null: false, default: {}
      t.jsonb :tags, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :source_documents, [ :knowledge_source_id, :external_id ], unique: true
    add_index :source_documents, [ :knowledge_source_id, :status ]
  end
end
