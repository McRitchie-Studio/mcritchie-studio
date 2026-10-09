# Drops the columns nothing reads or writes, and rebuilds the two timeline views,
# which select three of them, in the same transaction. No row is rewritten.
#
# Deploy order: the release before this one ignores these columns in its models,
# so its servers name none of them while the release phase runs this migration;
# the code that ships with it boots on the schema without them.
#
# Locks: DROP VIEW and DROP COLUMN take ACCESS EXCLUSIVE and change only the
# catalog. A statement that waits five seconds for its lock fails the migration,
# which rolls back whole; run it again.
#
# `down` rebuilds the columns, the index and the earlier views. It cannot bring
# back what the columns held.
#
# db/views holds the SQL `up` creates (test/db/timeline_views_test.rb). The
# baseline reads each `remove_column "table", "column"` line in `up`
# (DbBaseline.removed_columns), so a database past this migration is not short.
class DropDeadColumns < ActiveRecord::Migration[8.1]
  TASK_TIMELINE = <<~SQL.freeze
    CREATE VIEW task_timeline AS
    SELECT
      slug, title, stage, blocked_at, blocked_from, blocked_by, block_kind,
      created_at, updated_at, started_at,
      g1_testing_started_at, g1_testing_finished_at, g1_failed_at,
      submitted_at, reviewed_at, assembled_at, completed_at, archived_at,
      gates_cached_at, testing_phases_cached_at
    FROM tasks
  SQL

  RELEASE_TIMELINE = <<~SQL.freeze
    CREATE VIEW release_timeline AS
    SELECT
      slug, state, created_at, updated_at,
      testing_started_at, tested_at,
      assembling_started_at, assembled_at,
      qa_deploy_started_at, qa_deployed_at,
      confirming_started_at, confirmed_at,
      prod_deploy_started_at, shipped_at,
      abandoned_at, duration_metrics_cached_at
    FROM releases
  SQL

  PENDING_INDEX = "index_github_workflow_runs_on_pending_environment".freeze

  def up
    execute("SET LOCAL lock_timeout = '5s'")
    drop_views

    remove_column "tasks", "error_message", if_exists: true
    remove_column "tasks", "failed_at", if_exists: true
    remove_column "tasks", "queued_at", if_exists: true
    remove_column "tasks", "required_skills", if_exists: true
    remove_column "tasks", "sizes_revealed_at", if_exists: true
    remove_column "releases", "release_notes_sent_at", if_exists: true
    remove_index "github_workflow_runs", name: PENDING_INDEX, if_exists: true
    remove_column "github_workflow_runs", "pending_environment", if_exists: true
    remove_column "github_workflow_runs", "pending_since", if_exists: true
    remove_column "teams", "logo_path", if_exists: true
    remove_column "teams", "logo_source", if_exists: true
    remove_column "teams", "logo_url", if_exists: true
    remove_column "skill_assignments", "proficiency", if_exists: true

    execute(TASK_TIMELINE)
    execute(RELEASE_TIMELINE)
  end

  def down
    execute("SET LOCAL lock_timeout = '5s'")
    drop_views

    add_column "tasks", "error_message", :text, if_not_exists: true
    add_column "tasks", "failed_at", :datetime, if_not_exists: true
    add_column "tasks", "queued_at", :datetime, if_not_exists: true
    add_column "tasks", "required_skills", :jsonb, default: [], if_not_exists: true
    add_column "tasks", "sizes_revealed_at", :datetime, if_not_exists: true
    add_column "releases", "release_notes_sent_at", :datetime, if_not_exists: true
    add_column "github_workflow_runs", "pending_environment", :string, if_not_exists: true
    add_column "github_workflow_runs", "pending_since", :datetime, if_not_exists: true
    add_index "github_workflow_runs", [ "pending_environment" ], name: PENDING_INDEX,
              where: "(pending_environment IS NOT NULL)", if_not_exists: true
    add_column "teams", "logo_path", :string, if_not_exists: true
    add_column "teams", "logo_source", :string, if_not_exists: true
    add_column "teams", "logo_url", :string, if_not_exists: true
    add_column "skill_assignments", "proficiency", :integer, default: 100, if_not_exists: true

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

  private

  def drop_views
    execute("DROP VIEW IF EXISTS task_timeline")
    execute("DROP VIEW IF EXISTS release_timeline")
  end
end
