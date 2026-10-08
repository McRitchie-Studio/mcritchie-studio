# Columns nothing reads or writes, by table. Each model ignores its own
# (`self.ignored_columns += DeadColumns.for(table_name)`), so no statement names
# them and a reader raises instead of returning a stale value.
#
# Ignoring comes one release before the drop: an INSERT names every column the
# running code knows, so the servers still running the previous release during a
# deploy would fail every insert into a table whose column had just been dropped.
# Once this release is what runs, a migration drops the columns (and recreates
# the task_timeline and release_timeline views, which still select three of
# them) and this list empties. test/lib/dead_task_columns_grep_test.rb refuses a
# new reader in the meantime.
module DeadColumns
  BY_TABLE = {
    "tasks" => %w[failed_at queued_at sizes_revealed_at required_skills error_message],
    "releases" => %w[release_notes_sent_at],
    "github_workflow_runs" => %w[pending_environment pending_since],
    "teams" => %w[logo_path logo_source logo_url],
    "skill_assignments" => %w[proficiency]
  }.freeze

  def self.for(table) = BY_TABLE.fetch(table)
end
