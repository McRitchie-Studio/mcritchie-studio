# frozen_string_literal: true

# THE IDEMPOTENCY KEY for /tasks/harvest-stranded-ledger-stashes, enforced in the schema.
#
# `DeskRecord.file!` keys on `open_for(worktree_path)` — OPEN episodes only. Every one of
# the stranded rows is a RESOLVED `removed` episode, so `open_for` never matches one and a
# re-run of the harvest would file all of them a second time. That is not a hypothetical:
# the harvest reads 13 stashes across 13 different bases plus the primary's uncommitted
# tree, and a job with that many inputs is re-run.
#
# The key is a digest of the ledger row's own five cells (DeskLedgerImport.import_key), so
# identity is the ROW TEXT and nothing else. That is the same rule the markdown ledger
# used and the same one that must not be relaxed to the desk PATH: `_ship` is torn down
# every release cycle at the same path, and in the harvested set the two `_ship` paths
# carry 5 and 3 distinct teardowns respectively — a path-keyed import would destroy 6
# teardown records, which is the 2026-08-21 failure the ledger header records.
#
# It is a UNIQUE index rather than a read-then-write check in the model because that is
# the posture the rest of this table already takes: DeskRecord refuses a destructive write
# at the moment of the write instead of detecting it afterwards. A `find_by` guard alone
# is advisory — two harvests racing both miss and both insert — and the whole reason this
# ledger moved onto the board was to stop relying on somebody remembering.
#
# PARTIAL, so it constrains only imported rows. Every row filed by a teardown or a
# snapshot has no `import_key` and is untouched by this index — including the many rows
# that legitimately share a recycled `worktree_path`.
class AddImportKeyIndexToDeskRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :desk_records,
              "(payload->>'import_key')",
              unique: true,
              # Spelled as an IS NOT NULL test rather than jsonb's `?` containment
              # operator: a bare `?` inside a WHERE string is consumed as a bind
              # placeholder before Postgres ever sees it.
              where: "payload->>'import_key' IS NOT NULL",
              name: "index_desk_records_on_import_key"
  end
end
