# frozen_string_literal: true

# The desk ledger, moved off a markdown file and onto the board.
#
# `bin/agent-worktree remove` wrote its audit row into
# docs/agents/maintenance/delete-later.md, resolved against HUB_DIR — so a teardown run
# from the PRIMARY checkout (which is where cleanups are run) landed the row on `main`,
# a branch nobody may commit to. The record was created in the one place it could never
# be saved from. Twelve stashes of "restore later" ledger content accumulated between
# 2026-06-26 and 2026-08-31, 166 rows, none ever restored; a reclaim sweep on 2026-08-31
# stranded 25 more DURING the conversation about the defect.
#
# Two tables, because the panel has two questions to answer:
#   desk_records   — one row per desk EPISODE (a desk, and the teardown that resolved it)
#   desk_snapshots — one row per `bin/agent-worktree snapshot --write`, carrying the Redis
#                    band capacity and the sweep summary, which are properties of the RUN
#                    and not of any desk
class CreateDeskRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :desk_records do |t|
      # Identity. worktree_path is the desk directory — the same cell the markdown
      # ledger keyed on — and it RECYCLES (`_ship` is torn down every release cycle),
      # so it is deliberately not unique. The episode is (path, resolved_on).
      t.string :worktree_path, null: false
      t.string :label
      t.string :app_slug
      t.string :desk_slug
      t.string :task_slug
      t.string :task_url

      # Lifecycle. `live` while the desk exists, `candidate` once a sweep has nominated
      # it, `removed` once it is torn down. resolved_on is the DATE that made a markdown
      # row history (LedgerGuard.resolved_row?); the same definition governs here, so the
      # two media can never disagree about what an open row is.
      t.string :status, null: false, default: "live"
      t.date :resolved_on
      t.string :source
      t.string :actor

      # The safety argument — what a reader lands on months later.
      t.string :safety
      t.text :reason
      t.text :rationale
      t.text :withheld_reason
      t.text :safe_delete_condition
      t.boolean :cleanup_candidate, null: false, default: false

      # Git + stack facts, denormalized out of the registry so the panel renders
      # without unpacking JSON on every row.
      t.string :branch
      t.string :head
      t.string :commit_subject
      t.string :base_ref
      t.boolean :dirty, null: false, default: false
      t.boolean :merged, null: false, default: false
      t.string :ahead
      t.string :behind
      t.string :health
      t.string :local_url
      t.integer :app_port
      t.integer :redis_db
      t.string :database

      # The full registry record, verbatim. Nothing the snapshot knows is dropped on the
      # way in — which is also the door /tasks/harvest-stranded-ledger-stashes used to
      # import the 166 stranded rows, carrying each one's original ledger row and the stash
      # it was recovered from. The one thing it needed on top was a UNIQUE index on the
      # import key; see 20260901020000_add_import_key_index_to_desk_records.rb.
      t.jsonb :payload, null: false, default: {}

      # The snapshot generated_at that last SAW this desk. An open record older than the
      # newest snapshot is a desk that vanished without a teardown record — the defect
      # class this table exists to end, surfaced rather than assumed away.
      t.datetime :last_seen_at
      t.datetime :recorded_at

      t.timestamps
    end

    # The hot lookup is "the OPEN episode for this path" (DeskRecord.open_for).
    add_index :desk_records, [:worktree_path, :resolved_on]
    add_index :desk_records, :status
    add_index :desk_records, :app_slug
    add_index :desk_records, :resolved_on
    add_index :desk_records, :last_seen_at

    create_table :desk_snapshots do |t|
      t.datetime :generated_at, null: false
      t.string :projects_dir
      t.string :hub_dir
      t.integer :desk_count, null: false, default: 0
      t.jsonb :capacity, null: false, default: {}
      t.jsonb :summary, null: false, default: {}
      t.jsonb :redis_db_range, null: false, default: {}

      t.timestamps
    end

    add_index :desk_snapshots, :generated_at
  end
end
