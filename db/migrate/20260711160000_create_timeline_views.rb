# Two READ-ONLY inspection views that project the task + release pipeline
# timestamps in LOGICAL PROGRESS ORDER (the physical column order is alphabetical
# — a past rebuild — and Postgres can't reorder in place, so a view is the only
# way to read the lifecycle left-to-right). Operator-inspection-only: with the
# :ruby schema format a raw CREATE VIEW does NOT dump to schema.rb, so a fresh
# db:schema:load (test/CI) won't have these — do NOT back a model or a suite
# assertion on them existing in every env. Plain execute up/down (no scenic, no
# structure.sql), per the epic's deliberate choice.
class CreateTimelineViews < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL)
      CREATE VIEW task_timeline AS
      SELECT
        slug, title, stage, blocked_at, blocked_from, blocked_by, block_kind,
        created_at, updated_at,
        queued_at, sizes_revealed_at, started_at,
        g1_testing_started_at, g1_testing_finished_at, g1_failed_at,
        submitted_at, reviewed_at, assembled_at, completed_at, archived_at,
        gates_cached_at, testing_phases_cached_at
      FROM tasks
    SQL

    execute(<<~SQL)
      CREATE VIEW release_timeline AS
      SELECT
        slug, state, created_at, updated_at,
        testing_started_at, tested_at,
        assembling_started_at, assembled_at,
        qa_deploy_started_at, qa_deployed_at,
        confirming_started_at, confirmed_at,
        prod_deploy_started_at, shipped_at,
        abandoned_at, release_notes_sent_at, duration_metrics_cached_at
      FROM releases
    SQL
  end

  def down
    execute("DROP VIEW IF EXISTS release_timeline")
    execute("DROP VIEW IF EXISTS task_timeline")
  end
end
