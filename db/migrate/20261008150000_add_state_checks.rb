# State CHECK constraints, step 1 of 2: each stage, status and state column in
# StringStates::REGISTRY takes a CHECK (`<table>_<column>_known`) holding the list
# its model validates against, so a write that skips validations is refused by
# the database.
#
# The lists below are this migration's own frozen copy. A new value needs a new
# migration: test/models/state_check_constraints_test.rb fails while a model's
# list and its constraint differ.
#
# This step cannot fail on a row. Postgres checks a NOT VALID constraint on every
# later UPDATE of a row, whichever column changes, so a legacy row holding a value
# outside the list would become unsaveable. A column that holds such a value
# therefore takes no CHECK here: the migration names it and moves on, and
# `bin/rails state_checks:apply` (the task's post_deploy_cmd) adds it once the
# rows are resolved, exiting non-zero until then.
#
# Locks: the survey is a SELECT (ACCESS SHARE, blocks nothing). ADD CONSTRAINT
# ... NOT VALID takes ACCESS EXCLUSIVE on its one table and scans no rows, so it
# holds the lock for a catalog update. One statement per constraint, outside a
# transaction, with a short lock_timeout: an ALTER that cannot take its lock is
# retried, then left for state_checks:apply, so it never queues the board's
# writers behind it.
class AddStateChecks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s".freeze
  ATTEMPTS = 3

  CHECKS = {
    "agent_login_requests.status" => %w[pending granted refused],
    "app_requests.status" => %w[draft queued building live cancelled],
    "appearances.stage" => %w[designed defined source model generation],
    "broadcasts.status" => %w[draft sent],
    "contents.stage" => %w[idea hook script assets assembly posted reviewed],
    "credential_records.status" => %w[filed empty retired missing],
    "credential_vaults.status" => %w[active reserved retired],
    "desk_capture_items.status" => %w[received quarantined filed ignored],
    "desk_records.status" => %w[live candidate removing removed leaked],
    "import_runs.status" => %w[running ok failed],
    "music_videos.stage" => %w[digested cast_confirmed clips_ready],
    "news.stage" => %w[new reviewed processed refined concluded archived],
    "release_events.status" => %w[started completed failed],
    "releases.state" => %w[assembling assembled shipped abandoned],
    "review_pending_actions.state" => %w[pending executed expired refused disarmed],
    "source_documents.status" => %w[active missing],
    "staged_emails.status" => %w[staged approved sent cancelled skipped],
    "tasks.approval_status" => %w[waiting approved changes_requested none],
    "tasks.block_kind" => %w[environment rework dependency],
    "tasks.merged" => %w[accepted release main],
    "tasks.stage" => %w[designed building submitted reviewed assembled shipped archived],
    "tiktok_drafts.state" => %w[queued uploading processing unknown delivered failed],
    "triage_findings.prior_art" => %w[unknown none found],
    "triage_findings.status" => %w[open promoted dismissed],
    "video_clips.status" => %w[proposed approved rejected],
    "video_stitches.state" => %w[requested running done failed],
    "workspace_accounts.status" => %w[pending active revoked severed],
    "workspace_mailboxes.status" => %w[pending active revoked]
  }.freeze

  def up
    db.execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    CHECKS.each { |name, values| add_check(*name.split("."), values) }
  ensure
    db.execute "RESET lock_timeout"
  end

  def down
    CHECKS.each_key do |name|
      table, column = name.split(".")
      db.execute "ALTER TABLE #{db.quote_table_name(table)} DROP CONSTRAINT IF EXISTS #{db.quote_column_name("#{table}_#{column}_known")}"
    end
  end

  private

  # The connection, called directly so each statement is not echoed as a
  # migration step.
  def db = connection

  def add_check(table, column, values)
    constraint = "#{table}_#{column}_known"
    return if check_exists?(table, constraint)

    list = values.map { |value| db.quote(value) }.join(", ")
    col = db.quote_column_name(column)
    strays = db.select_rows("SELECT #{col}, COUNT(*) FROM #{db.quote_table_name(table)} " \
                            "WHERE #{col} IS NOT NULL AND #{col} NOT IN (#{list}) GROUP BY #{col} ORDER BY #{col}")
    if strays.any?
      say "#{table}.#{column}: no CHECK added; rows hold values outside the list: " \
          "#{strays.map { |value, count| "#{value.to_s.truncate(40).inspect} x#{count}" }.join(", ")}"
      return
    end

    attempt = 0
    begin
      attempt += 1
      db.execute "ALTER TABLE #{db.quote_table_name(table)} ADD CONSTRAINT #{db.quote_column_name(constraint)} " \
                 "CHECK (#{col} IN (#{list})) NOT VALID"
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
      if attempt < ATTEMPTS
        sleep attempt
        retry
      end
      say "#{table}.#{column}: lock not granted in #{ATTEMPTS} tries; left for bin/rails state_checks:apply"
    end
  end

  def check_exists?(table, constraint)
    db.select_value("SELECT 1 FROM pg_constraint WHERE contype = 'c' AND conrelid = #{db.quote(table)}::regclass " \
                    "AND conname = #{db.quote(constraint)}").present?
  end
end
