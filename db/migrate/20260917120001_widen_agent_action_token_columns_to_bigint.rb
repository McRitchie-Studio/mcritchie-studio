# Widen `agent_actions`' token counters to int8 — SPLIT OUT from the previous
# migration on purpose.
#
# READ THIS BEFORE DEPLOYING. `agent_actions` is the hub's high-volume table and
# is the ONLY one of the five whose rewrite is not instant. Measured on
# production 2026-09-17:
#
#   agent_actions   291,963 rows   445 MB heap   73 MB indexes   286 MB toast
#
# An int4 -> int8 ALTER is a full table rewrite plus a rebuild of all seven
# indexes, held under ACCESS EXCLUSIVE for the duration. TOAST is not rewritten
# (only its pointers are copied), so the work is ~445 MB read + ~450 MB written
# plus the index rebuilds. On this plan expect roughly 15-45 seconds, and budget
# up to ~2 minutes. Every read and write of `agent_actions` blocks for that
# window, which means trajectory narration and the /agents pages stall.
#
# WHY IT IS ITS OWN MIGRATION: Rails wraps each migration in its own transaction.
# Bundled with the small tables, a `lock_timeout` abort here would roll back the
# fix for `task_events` too — and `task_events` is the table that actually
# overflowed. Split, the real fix commits first and this one can be retried on
# its own (`bin/rails db:migrate:up VERSION=20260917120001`).
#
# WHY IT IS STILL WORTH DOING: `agent_actions` stores PER-CALL deltas, so its
# measured maxima are nowhere near the ceiling — cache_read_tokens max 999,485
# and tokens_in max 973,792, both under 0.05% of int4. It is not urgent. It is
# included because leaving one table of the set narrow is how this recurs, and
# because the table only grows: doing it at 292k rows is cheaper than doing it
# at 3M.
#
# The three columns are widened in ONE statement so the heap is rewritten once
# rather than three times.
class WidenAgentActionTokenColumnsToBigint < ActiveRecord::Migration[7.2]
  COLUMNS = %w[tokens_in tokens_out cache_read_tokens].freeze

  def up
    # Short lock_timeout: refuse to QUEUE behind a live query. Production runs
    # lock_timeout = 0, so without this the ALTER would wait indefinitely while
    # every subsequent statement piled up behind its lock request.
    execute "SET LOCAL lock_timeout = '10s'"
    # Generous statement_timeout: once the lock is held, let the rewrite finish.
    # Being killed mid-rewrite would roll back cleanly but waste the lock window.
    execute "SET LOCAL statement_timeout = '15min'"
    retype("bigint")
  end

  def down
    execute "SET LOCAL lock_timeout = '10s'"
    execute "SET LOCAL statement_timeout = '15min'"
    retype("integer")
  end

  private

  def retype(type)
    changes = COLUMNS.map { |column| "ALTER COLUMN #{quote_column_name(column)} TYPE #{type}" }
    execute "ALTER TABLE #{quote_table_name(:agent_actions)} #{changes.join(', ')}"
  end
end
