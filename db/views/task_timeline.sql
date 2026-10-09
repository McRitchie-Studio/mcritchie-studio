CREATE VIEW task_timeline AS
SELECT
  slug, title, stage, blocked_at, blocked_from, blocked_by, block_kind,
  created_at, updated_at,
  queued_at, sizes_revealed_at, started_at,
  g1_testing_started_at, g1_testing_finished_at, g1_failed_at,
  submitted_at, reviewed_at, assembled_at, completed_at, archived_at,
  gates_cached_at, testing_phases_cached_at
FROM tasks
