require "test_helper"
require "rake"
require Rails.root.join("db/migrate/20261008150000_add_state_checks")
require Rails.root.join("db/migrate/20261008150100_validate_state_checks")

# [integration] StateCheckConstraints and the two state-check migrations against
# rows that predate the constraints: the census is read-only and names a stray
# value, neither migration fails on one, and apply finishes the work once the
# row is resolved. DDL is transactional in Postgres, so each test's rollback
# restores the constraints it removes.
class StateCheckCensusTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection
  def service = StateCheckConstraints.new
  def row(name) = service.census.rows.find { |r| r.name == name }

  def statements
    events = []
    callback = lambda do |*, payload|
      events << [ payload[:sql], ActiveRecord::Base.current_preventing_writes ] unless %w[CACHE SCHEMA].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    events
  end

  def non_selects(events) = events.map(&:first).reject { |sql| sql.lstrip.match?(/\ASELECT\b/i) }

  # A task row as it could stand before the constraints: a stray approval status
  # and a NULL stage, with the constraints that would refuse them removed.
  def strand_legacy_rows
    connection.execute "ALTER TABLE tasks DROP CONSTRAINT tasks_approval_status_known"
    connection.execute "ALTER TABLE tasks ALTER COLUMN stage DROP NOT NULL"
    Task.where(id: tasks(:new_task).id).update_all(approval_status: "pending_review")
    Task.where(id: tasks(:queued_task).id).update_all(stage: nil)
  end

  def quietly
    was = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    yield
  ensure
    ActiveRecord::Migration.verbose = was
  end

  test "[integration] a full census is read-only: SELECTs only, writes prevented throughout" do
    census = nil
    events = statements { census = service.census }

    assert_operator events.size, :>=, StringStates::REGISTRY.size + StringStates::UNCONSTRAINED.size
    assert_empty non_selects(events), "every census statement must be a SELECT"
    assert events.all?(&:last), "every statement must run inside while_preventing_writes"
    assert census.settled?, census.lines.join("\n")
  end

  test "[integration] control: an UPDATE fails the read-only measure" do
    events = statements { Task.where(id: tasks(:new_task).id).update_all(position: 1) }

    assert_equal 1, non_selects(events).size
    assert_not events.all?(&:last)
  end

  test "[integration] the census names a stray value and a NULL stage, with counts and no row" do
    strand_legacy_rows
    census = service.census

    stray = census.rows.find { |r| r.name == "tasks.approval_status" }
    assert_equal :missing, stray.state
    assert_equal({ "pending_review" => 1 }, stray.strays)
    assert_equal 1, census.null_stages
    assert census.stage_nullable
    assert_not census.settled?
    assert_includes census.lines, %(tasks.approval_status: missing · outside the list: "pending_review" x1)
    assert_includes census.lines, "tasks.stage: nullable · NULL rows: 1"
    assert_not_includes census.lines.join, tasks(:new_task).slug
  end

  test "[integration] neither migration fails on a stray row, and no constraint lands over one" do
    strand_legacy_rows
    connection.execute "ALTER TABLE releases DROP CONSTRAINT releases_state_known"

    quietly do
      AddStateChecks.new.up
      ValidateStateChecks.new.up
    end

    assert_equal :missing, row("tasks.approval_status").state, "a CHECK over a stray row would make it unsaveable"
    assert service.census.stage_nullable
    assert_equal :valid, row("releases.state").state, "a clean column is added and validated"
    assert tasks(:new_task).reload.update(title: "Still saveable"), "the legacy row still saves"
  end

  test "[integration] validate leaves a NOT VALID constraint over a stray row and names nothing as valid" do
    strand_legacy_rows
    connection.execute "ALTER TABLE tasks ADD CONSTRAINT tasks_approval_status_known " \
                       "CHECK (approval_status IN ('waiting', 'approved', 'changes_requested', 'none')) NOT VALID"

    quietly { ValidateStateChecks.new.up }

    assert_equal :not_valid, row("tasks.approval_status").state
  end

  test "[integration] apply leaves a stray column alone, then finishes once the rows are resolved" do
    strand_legacy_rows

    assert_not service.apply.settled?
    assert_equal :missing, row("tasks.approval_status").state

    Task.where(approval_status: "pending_review").update_all(approval_status: nil)
    Task.where(stage: nil).update_all(stage: "archived")
    census = service.apply

    assert census.settled?, census.lines.join("\n")
    assert_equal :valid, row("tasks.approval_status").state
    assert_not census.stage_nullable
  end

  test "[integration] state_checks:census prints the report and aborts while a constraint is unsettled" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("state_checks:census")
    Rake::Task["state_checks:census"].reenable
    out, = capture_io { Rake::Task["state_checks:census"].invoke }
    assert_includes out, "tasks.stage: valid"
    assert_includes out, "state checks: every constraint valid, tasks.stage NOT NULL"

    strand_legacy_rows
    Rake::Task["state_checks:census"].reenable
    error = nil
    capture_io { error = assert_raises(SystemExit) { Rake::Task["state_checks:census"].invoke } }
    assert_not error.success?
  end

  def run_apply
    Rails.application.load_tasks unless Rake::Task.task_defined?("state_checks:apply")
    Rake::Task["state_checks:apply"].reenable
    capture_io { Rake::Task["state_checks:apply"].invoke }.first
  end

  def signal = TriageFinding.find_by(slug: StateCheckConstraints::SIGNAL_SLUG)

  # The post-deploy hook: the release stops on a hook that exits non-zero, so the
  # rows never decide its exit.
  test "[integration] state_checks:apply over a stray value and a NULL stage exits 0, settles the clean and records one finding" do
    strand_legacy_rows
    connection.execute "ALTER TABLE releases DROP CONSTRAINT releases_state_known"

    out = nil
    assert_difference "TriageFinding.count", 1 do
      assert_nothing_raised { out = run_apply }
    end

    assert_equal :valid, row("releases.state").state, "a clean column is settled"
    assert_equal :missing, row("tasks.approval_status").state, "a stray column stays unconstrained"
    assert service.census.stage_nullable
    assert_includes out, "STATE CHECKS UNSETTLED"
    assert_includes out, "recorded as triage finding state-checks-unsettled (open)"

    finding = signal
    assert_equal "open", finding.status
    assert_equal "State CHECK constraints unsettled: 2", finding.title
    assert_includes finding.body, "- tasks.approval_status (tasks_approval_status_known): missing · 1 value(s) outside the list in 1 row(s)"
    assert_includes finding.body, "- tasks.stage: nullable · NULL rows: 1"
    assert_not_includes finding.body, "pending_review", "the finding carries counts, never a value"
    assert_not_includes finding.body, tasks(:new_task).slug
  end

  test "[integration] a second apply rewrites the one finding, and a settled run dismisses it" do
    strand_legacy_rows
    run_apply
    Task.where(stage: nil).update_all(stage: "archived")

    assert_no_difference "TriageFinding.count" do
      run_apply
    end
    assert_equal "State CHECK constraints unsettled: 1", signal.title
    assert_not_includes signal.body, "tasks.stage: nullable"

    signal.dismiss!
    assert_no_difference("TriageFinding.count") { run_apply }
    assert_equal "open", signal.status, "a finding dismissed while the column is still unsettled reopens"

    Task.where(approval_status: "pending_review").update_all(approval_status: nil)
    out = nil
    assert_no_difference("TriageFinding.count") { out = run_apply }
    assert_equal "dismissed", signal.status
    assert_includes out, "state checks: every constraint valid, tasks.stage NOT NULL"
  end

  test "[integration] a settled apply records nothing" do
    assert_no_difference("TriageFinding.count") { run_apply }
  end

  test "[integration] a lock not granted inside apply is named on the census, not raised" do
    strand_legacy_rows
    Task.where(approval_status: "pending_review").update_all(approval_status: nil)
    stuck = service
    stuck.define_singleton_method(:add) { |_column| raise ActiveRecord::LockWaitTimeout, "canceling statement due to lock timeout" }

    census = stuck.apply

    assert_equal "lock wait timeout", census.stopped
    assert_not census.settled?
    assert_includes census.unsettled_summary, "apply stopped early: lock wait timeout"
  end

  test "[integration] a survey the database cancels reads as unknown rows, never as clean" do
    timed_out = service
    timed_out.define_singleton_method(:strays) do |column|
      raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout" if column.name == "tasks.merged"

      {}
    end

    stray = timed_out.census.rows.find { |r| r.name == "tasks.merged" }

    assert stray.unread
    assert_not stray.clean?
    assert_not stray.settled?
    assert_includes stray.summary, "survey timed out"
  end

  test "[integration] control: an unexpected exception still fails state_checks:apply" do
    boom = Class.new(StandardError)
    broken = service
    broken.define_singleton_method(:apply) { raise boom, "not a data condition" }

    StateCheckConstraints.stub(:new, broken) do
      assert_raises(boom) { run_apply }
    end
  end

  test "[integration] a helper CHECK left by a half-finished NOT NULL is removed by the next run and by down" do
    helper = -> { connection.select_value("SELECT 1 FROM pg_constraint WHERE conname = 'tasks_stage_present'") }
    connection.execute "ALTER TABLE tasks ADD CONSTRAINT tasks_stage_present CHECK (stage IS NOT NULL) NOT VALID"

    quietly { ValidateStateChecks.new.up }
    assert_nil helper.call, "a re-run of up removes it"

    connection.execute "ALTER TABLE tasks ADD CONSTRAINT tasks_stage_present CHECK (stage IS NOT NULL) NOT VALID"
    service.apply
    assert_nil helper.call, "apply removes it"

    connection.execute "ALTER TABLE tasks ADD CONSTRAINT tasks_stage_present CHECK (stage IS NOT NULL) NOT VALID"
    quietly { ValidateStateChecks.new.down }
    assert_nil helper.call, "down removes it"
    assert service.census.stage_nullable
  end

  test "[integration] a survey that times out in the add migration skips its column" do
    connection.execute "ALTER TABLE releases DROP CONSTRAINT releases_state_known"
    migration = AddStateChecks.new
    slow = connection
    real = slow.method(:select_rows)
    slow.define_singleton_method(:select_rows) do |sql, *rest, **options|
      raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout" if sql.include?("FROM \"releases\"")

      real.call(sql, *rest, **options)
    end

    begin
      quietly { assert_nothing_raised { migration.up } }
    ensure
      slow.singleton_class.send(:remove_method, :select_rows)
    end

    assert_equal :missing, row("releases.state").state
  end
end
