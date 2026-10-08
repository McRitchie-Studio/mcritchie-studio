# State CHECK constraints, step 2 of 2: VALIDATE each `<table>_<column>_known`
# constraint step 1 added, and make tasks.stage NOT NULL. It writes no rows.
#
# Like step 1, this step cannot fail on a row: a constraint whose column holds a
# value outside its list stays NOT VALID (still refusing new writes), and a NULL
# tasks.stage leaves the column nullable; each is named, and
# `bin/rails state_checks:apply` (the post-deploy hook, which exits 0 and keeps
# one triage finding while anything is left) finishes the work once the rows are
# resolved. A survey or a VALIDATE the database cancels on a statement timeout is
# skipped the same way.
#
# Locks: VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE, which blocks neither
# reads nor writes, for one scan of its table (milliseconds on `tasks`; the
# largest table here is a few thousand rows).
#
# tasks.stage NOT NULL: a CHECK (stage IS NOT NULL) is added NOT VALID and
# validated under that same weak lock; SET NOT NULL then takes ACCESS EXCLUSIVE
# but reads the validated CHECK as its proof and scans nothing; the helper CHECK
# is dropped (ACCESS EXCLUSIVE, catalog only). The column already defaults to
# "designed". A helper left behind by a pass that stopped halfway is removed by
# the next run and by `down`.
#
# One statement at a time, outside a transaction, with a short lock_timeout; a
# statement that cannot take its lock is left for state_checks:apply.
class ValidateStateChecks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s".freeze
  STAGE_PRESENT = "tasks_stage_present".freeze

  def up
    db.execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    unvalidated_state_checks.each { |check| validate_check(check["table_name"], check["name"], check["expression"]) }
    require_task_stage
  ensure
    db.execute "RESET lock_timeout"
  end

  # A valid constraint is also a working NOT VALID one, and step 1's down removes
  # them; only the NOT NULL has an inverse.
  def down
    db.execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    db.execute "ALTER TABLE tasks DROP CONSTRAINT IF EXISTS #{STAGE_PRESENT}"
    change_column_null :tasks, :stage, true
  ensure
    db.execute "RESET lock_timeout"
  end

  private

  def db = connection

  def unvalidated_state_checks
    db.select_all(<<~SQL.squish).to_a
      SELECT con.conname AS name, rel.relname AS table_name, pg_get_expr(con.conbin, con.conrelid) AS expression
      FROM pg_constraint con JOIN pg_class rel ON rel.oid = con.conrelid
      WHERE con.contype = 'c' AND NOT con.convalidated AND con.conname LIKE '%\\_known'
      ORDER BY rel.relname, con.conname
    SQL
  end

  def validate_check(table, constraint, expression)
    strays = db.select_value("SELECT COUNT(*) FROM #{db.quote_table_name(table)} WHERE NOT (#{expression})").to_i
    if strays.positive?
      say "#{constraint}: #{strays} rows hold a value outside the list; left NOT VALID for bin/rails state_checks:apply"
      return
    end

    db.execute "ALTER TABLE #{db.quote_table_name(table)} VALIDATE CONSTRAINT #{db.quote_column_name(constraint)}"
  rescue ActiveRecord::QueryCanceled
    say "#{constraint}: timed out; left NOT VALID for bin/rails state_checks:apply"
  rescue ActiveRecord::CheckViolation
    say "#{constraint}: a row holds a value outside the list; left NOT VALID for bin/rails state_checks:apply"
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
    say "#{constraint}: lock not granted; left NOT VALID for bin/rails state_checks:apply"
  end

  def require_task_stage
    leftover = db.select_value("SELECT 1 FROM pg_constraint WHERE conrelid = 'tasks'::regclass AND conname = '#{STAGE_PRESENT}'")
    db.execute "ALTER TABLE tasks DROP CONSTRAINT #{STAGE_PRESENT}" if leftover
    return unless db.select_value("SELECT is_nullable FROM information_schema.columns " \
                                  "WHERE table_schema = current_schema() AND table_name = 'tasks' AND column_name = 'stage'") == "YES"

    nulls = db.select_value("SELECT COUNT(*) FROM tasks WHERE stage IS NULL").to_i
    if nulls.positive?
      say "tasks.stage: #{nulls} rows hold NULL; left nullable for bin/rails state_checks:apply"
      return
    end

    db.execute "ALTER TABLE tasks ADD CONSTRAINT #{STAGE_PRESENT} CHECK (stage IS NOT NULL) NOT VALID"
    db.execute "ALTER TABLE tasks VALIDATE CONSTRAINT #{STAGE_PRESENT}"
    db.execute "ALTER TABLE tasks ALTER COLUMN stage SET NOT NULL"
    db.execute "ALTER TABLE tasks DROP CONSTRAINT #{STAGE_PRESENT}"
  rescue ActiveRecord::CheckViolation, ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::QueryCanceled => e
    say "tasks.stage: NOT NULL not set (#{e.class.name.demodulize}); left for bin/rails state_checks:apply"
  end
end
