# The evidence behind a `leaked` desk record: each process a teardown left running because
# it could not prove the process was the desk's own (bin/agent-worktree#cwd_is_desk?).
# [{"pid":, "label":, "via": "pidfile"|"port", "port":, "cwd":}, ...]
#
# Additive, with a constant default: on Postgres 11+ this is a catalog-only change, so the
# table is not rewritten and the lock is held for milliseconds.
class AddLeakedProcessesToDeskRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :desk_records, :leaked_processes, :jsonb, default: [], null: false
  end
end
