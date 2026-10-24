# Steffon's nightly agent job over the database backups, registered in
# config/recurring.yml for production at 03:30 America/Denver, after Heroku's
# 02:00 scheduled captures. It checks every backed-up app's latest Heroku
# Postgres backup, captures one where none completed in 26 hours, records what
# it saw for the 07:00 daily app report, and opens or resolves the floor
# incidents AgentMessages::FloorAlert announces once. See DbBackupSweep and
# docs/agents/agents/steffon/sops/db-restore-drill.md.
#
# Inert (one log line) until HEROKU_BACKUP_API_KEY is set. Best-effort, like
# DailyAppReportJob: an unexpected failure is an ErrorLog receipt, never a retry
# storm; tomorrow's run is the retry.
class DbBackupSweepJob < ApplicationJob
  queue_as :default

  def perform
    # QA boots RAILS_ENV=production; only production's board sweeps.
    return if Studio.qa_environment?

    DbBackupSweep.new.call
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
