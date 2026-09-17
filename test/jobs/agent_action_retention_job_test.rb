require "test_helper"

# agent_actions retention. Mr. McRitchie's rule, 2026-09-16: "I only want to delete
# rows older than 45 days old." So the boundary is the contract: a row OLDER than 45
# days goes, a row exactly 45 days old or newer stays. Every test freezes the clock so
# "45 days" is an exact instant rather than a moving target.
class AgentActionRetentionJobTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 17, 12, 0, 0)

  def action_at(occurred_at, created_at: occurred_at, **attrs)
    AgentAction.create!({ session_id: "retention-probe", kind: "bash", occurred_at: occurred_at,
                          created_at: created_at, updated_at: created_at }.merge(attrs))
  end

  def run_job(**kwargs)
    AgentActionRetentionJob.perform_now(pause: 0, **kwargs)
  end

  def exists?(action)
    AgentAction.exists?(action.id)
  end

  test "[unit] the boundary is exact: older than 45 days goes, 45 days old and newer stays" do
    travel_to(NOW) do
      forty_six_days    = action_at(46.days.ago)
      just_past_window  = action_at(45.days.ago - 1.second)
      exactly_45_days   = action_at(45.days.ago)
      just_inside       = action_at(45.days.ago + 1.second)
      today             = action_at(1.minute.ago)

      result = run_job

      assert_not exists?(forty_six_days), "a 46-day-old row is past the window and must be deleted"
      assert_not exists?(just_past_window), "one second past 45 days is OLDER than 45 days"
      assert exists?(exactly_45_days), "a row exactly 45 days old is NOT older than 45 days; it stays"
      assert exists?(just_inside), "a row inside the window stays"
      assert exists?(today), "a fresh row stays"
      assert_equal 2, result.deleted
      assert_equal NOW - 45.days, result.cutoff
      assert_equal 3_888_000, (NOW - result.cutoff).to_i, "45 days is exactly 45 * 86,400 seconds in UTC"
    end
  end

  test "[unit] the clock is occurred_at, not created_at" do
    travel_to(NOW) do
      old_action_recent_write = action_at(60.days.ago, created_at: 1.day.ago)
      new_action_old_write    = action_at(1.day.ago, created_at: 60.days.ago)

      run_job

      assert_not exists?(old_action_recent_write),
                 "an action that HAPPENED 60 days ago is past the window, whenever it was written"
      assert exists?(new_action_old_write),
             "an action that happened yesterday stays, even with an old created_at"
    end
  end

  test "[unit] a graded action is kept with its banked grade; an activity grade does not stall the run" do
    travel_to(NOW) do
      graded = action_at(90.days.ago, task_slug: "graded-probe")
      grade = ActionGrade.create!(agent_action: graded, grader: ActionGrade::ALEX,
                                  slug: "keep the lesson source", disposition: ActionGrade::GOOD)
      grade.bank!

      # An ACTIVITY-target grade carries a NULL agent_action_id. Under a NOT IN
      # (SELECT agent_action_id ...) guard that one NULL would match nothing and the job
      # would delete zero rows, forever, reporting success.
      activity = AgentActivity.create!(session_id: "retention-probe", category: "Explore",
                                       reason_slug: "probe", opened_at: 90.days.ago, seq: 0)
      ActionGrade.create!(agent_activity: activity, grader: ActionGrade::ALEX,
                          slug: "an activity lesson", disposition: ActionGrade::GOOD)
      ungraded = action_at(90.days.ago)

      result = run_job

      assert exists?(graded), "a graded action is the source of an Insight Bank lesson; it must stay"
      assert ActionGrade.exists?(grade.id), "and so must the grade that hangs off it"
      assert_not exists?(ungraded), "an ungraded old action still goes, with activity grades present"
      assert_equal 1, result.deleted
      assert_equal 1, result.retained
    end
  end

  test "[unit] every CI test-scope slug is kept; a NULL or other event_slug is not" do
    travel_to(NOW) do
      ci_rows = Task::TestingPhases::CI_SCOPES.map do |slug|
        action_at(90.days.ago, kind: "test_scope", event_slug: slug, task_slug: "ci-probe", result_slug: "pass")
      end
      null_slug  = action_at(90.days.ago, event_slug: nil)
      other_slug = action_at(90.days.ago, kind: "test_scope", event_slug: "full_suite_test", result_slug: "pass")

      result = run_job

      ci_rows.each do |row|
        assert exists?(row), "#{row.event_slug} rebuilds a task's CI phase; deleting it blanks that phase"
      end
      assert_not exists?(null_slug), "a bare NOT IN would silently keep every NULL event_slug row"
      assert_not exists?(other_slug), "a non-CI test scope is ordinary telemetry past the window"
      assert_equal 2, result.deleted
      assert_equal Task::TestingPhases::CI_SCOPES.size, result.retained
    end
  end

  test "[unit] a re-run is idempotent and deletes nothing more" do
    travel_to(NOW) do
      3.times { action_at(50.days.ago) }
      kept = action_at(10.days.ago)

      assert_equal 3, run_job.deleted
      second = run_job

      assert_equal 0, second.deleted
      assert second.drained
      assert exists?(kept)
    end
  end

  test "[unit] each run logs how many rows it deleted" do
    travel_to(NOW) do
      2.times { action_at(50.days.ago) }
      lines = []
      logger = Rails.logger
      logger.stub(:info, ->(message = nil, &_block) { lines << message.to_s }) { run_job }

      line = lines.find { |l| l.start_with?("[AgentActionRetentionJob]") }
      assert line, "a run must leave a log line"
      assert_match(/deleted 2 agent_actions row\(s\)/, line)
      assert_match(/occurred_at < 2026-08-03T12:00:00Z/, line)
      assert_match(/drained/, line)
    end
  end

  test "[unit] a failure is written to an ErrorLog and not re-raised" do
    travel_to(NOW) do
      action_at(50.days.ago)

      AgentActionRetentionJob.stub(:expired, ->(_cutoff) { raise ActiveRecord::StatementInvalid, "probe failure" }) do
        assert_difference -> { ErrorLog.count }, 1 do
          assert_nil run_job
        end
      end

      log = ErrorLog.order(:id).last
      assert_match(/probe failure/, log.message)
      assert_equal "agent_actions", log.target_name
    end
  end

  test "[unit] the job is registered as a production recurring job with a parseable schedule" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production", {})
    entry = schedule.values.find { |e| e["class"] == "AgentActionRetentionJob" }

    assert entry, "config/recurring.yml must schedule AgentActionRetentionJob, or retention never runs"
    # Validated through Solid Queue's OWN loader, so a schedule it would reject at boot
    # (not a cron, or a class it cannot resolve) fails here instead of silently never firing.
    task = SolidQueue::RecurringTask.from_configuration("agent_action_retention", **entry.symbolize_keys)
    assert task.valid?, "recurring entry rejected by Solid Queue: #{task.errors.full_messages.to_sentence}"
  end
end
