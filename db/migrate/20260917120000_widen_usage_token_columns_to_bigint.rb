# Widen every usage/token counter that carries a CUMULATIVE count from int4 to
# int8.
#
# WHY: `cache_read_tokens` is a running session total, not a per-call delta, and
# on 2026-09-17 it passed int4's ceiling in production:
#
#   bin/task move <slug> archived
#   422: 2231911675 is out of range for ActiveModel::Type::Integer with limit 4 bytes
#
# The write sits in Task's `after_update` transition callback (app/models/task.rb
# :531 -> #write_stage_event), so the overflow did not merely drop telemetry — it
# rolled back the STAGE CHANGE. Measured on production the same day:
#
#   task_events.cache_read_tokens  max 2_028_593_445  (94.5% of int4)
#   task_events.tokens_in          max   748_775_466  (34.9% of int4)
#   agent_activities.cache_read    max   280_507_124  (13.1% of int4)
#
# These are legitimate values from long sessions, so the column was simply the
# wrong width. `agent_actions` is widened separately (see the next migration) —
# it is the only one of these tables large enough for the rewrite to matter.
#
# SAFETY: production runs `lock_timeout = 0` and `statement_timeout = 0`, so an
# ALTER that blocks would wait forever for its ACCESS EXCLUSIVE lock AND queue
# every later query behind that lock REQUEST. `SET LOCAL lock_timeout` makes the
# migration fail fast instead of taking the board down; the release phase then
# rejects the deploy, which is the outcome we want. Each table's columns are
# widened in ONE statement so the heap is rewritten once, not four times.
#
# Combined size of the four tables below on production: ~15 MB of heap and
# ~10 MB of indexes. Expected lock: well under one second.
class WidenUsageTokenColumnsToBigint < ActiveRecord::Migration[7.2]
  COLUMNS = {
    task_events: %w[tokens_in tokens_out cache_creation_tokens cache_read_tokens],
    agent_activities: %w[tokens_in tokens_out cache_creation_tokens cache_read_tokens],
    release_events: %w[tokens_in tokens_out],
    usages: %w[tokens_in tokens_out]
  }.freeze

  def up
    execute "SET LOCAL lock_timeout = '10s'"
    COLUMNS.each { |table, columns| retype(table, columns, "bigint") }
  end

  # Reversible, but a revert REFUSES when live data has already outgrown int4 —
  # PostgreSQL raises rather than silently truncating. That refusal is correct:
  # narrowing these columns back is what caused the incident.
  def down
    execute "SET LOCAL lock_timeout = '10s'"
    COLUMNS.each { |table, columns| retype(table, columns, "integer") }
  end

  private

  def retype(table, columns, type)
    changes = columns.map { |column| "ALTER COLUMN #{quote_column_name(column)} TYPE #{type}" }
    execute "ALTER TABLE #{quote_table_name(table)} #{changes.join(', ')}"
  end
end
