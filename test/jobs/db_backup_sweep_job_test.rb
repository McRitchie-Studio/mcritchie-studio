require "test_helper"

# [integration] DbBackupSweepJob, Steffon's nightly agent job: scheduled at
# 03:30 Denver in production (after Heroku's 02:00 captures), inert without the
# key, quiet on QA, and never a crash. Nothing reaches Heroku.
class DbBackupSweepJobTest < ActiveJob::TestCase
  test "[integration] the job is scheduled at 03:30 Denver in production, after the 02:00 captures" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "db_backup_sweep")

    assert_equal "DbBackupSweepJob", entry["class"]
    assert_equal "30 3 * * * America/Denver", entry["schedule"]
    assert_equal [], entry["args"]
    assert_kind_of Class, entry["class"].constantize
  end

  test "[integration] without HEROKU_BACKUP_API_KEY the run is one log line and touches nothing" do
    with_env("HEROKU_BACKUP_API_KEY", nil) do
      log = StringIO.new
      Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
        assert_no_difference [ "AgentMailboxIncident.count", "ErrorLog.count", "App.where.not(backup_status: {}).count" ] do
          DbBackupSweepJob.perform_now
        end
      end
      assert_match(/\[db-backup-sweep\] inert: HEROKU_BACKUP_API_KEY is unset/, log.string)
    end
  end

  test "[integration] QA's production boot never sweeps" do
    called = false
    Studio.stub(:qa_environment?, true) do
      DbBackupSweep.stub(:new, ->(*) { called = true }) { DbBackupSweepJob.perform_now }
    end
    refute called
  end

  test "[integration] an unexpected failure is an ErrorLog receipt, not a raise" do
    boom = Object.new
    def boom.call = raise(ArgumentError, "unexpected")

    DbBackupSweep.stub(:new, boom) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised { DbBackupSweepJob.perform_now }
      end
    end
  end
end
