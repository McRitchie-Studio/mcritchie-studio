# Two READ-ONLY inspection views that project the task + release lifecycle in
# LOGICAL STAGE ORDER — the order the pipeline PROGRESSES through, which is NOT
# wall-clock order. (The physical column order is alphabetical, a past rebuild,
# and Postgres can't reorder in place; hence a view.)
#
# LOGICAL, NOT CHRONOLOGICAL. release_timeline mirrors Release::STAGES, the same
# canonical order the /deployments tracker uses. Release stamps deliberately land
# out of wall-clock order — assembling_started_at is stamped back at MERGE time
# (Conductor.sweep!) and qa_deploy_started_at before the QA deploy, both BEFORE
# qa_green! stamps tested_at — which is exactly why Release#current_stage is
# documented MONOTONIC. Do not "fix" this by re-ordering to chronology: logical
# progress order is the whole product.
#
# CAVEAT (:ruby schema): a raw CREATE VIEW does NOT dump to schema.rb, so a fresh
# db:schema:load (test/CI) won't have these. Operator-inspection-only — don't back
# a model or suite assertion on them existing in every env.
#
# COLUMN NOTES (deliberate, not oversight):
#   * task_timeline's block set (blocked_at/_from/_by/kind) is a STATUS HEADER, not
#     a link in the progress chain — Task#clear_block_on_forward_move NULLs all four
#     the moment a task leaves `building`, so they are populated only while it is
#     CURRENTLY blocked.
#   * Permanently NULL today (kept so the declared lifecycle stays complete, but a
#     reader should know): releases.testing_started_at (no producer — tracker node 1
#     greens off `assembling`), tasks.queued_at, tasks.sizes_revealed_at.
#   * tasks.failed_at is deliberately OMITTED (dead column, not part of the flow).
class CreateTimelineViews < ActiveRecord::Migration[8.1]
  def up
    # DROP+CREATE, never CREATE OR REPLACE: Postgres cannot reorder or drop an
    # existing view's columns with OR REPLACE, and column ORDER is this view's
    # entire purpose. This also makes `up` re-runnable, which the schema-load
    # footgun (see docs) actually requires of the operator.
    execute("DROP VIEW IF EXISTS release_timeline")
    execute("DROP VIEW IF EXISTS task_timeline")

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
