# frozen_string_literal: true

require "test_helper"

# The task_timeline / release_timeline views are raw `CREATE VIEW` SQL
# (db/views/*.sql, carried by the newest migration that creates each view), which
# does NOT dump to the :ruby schema, so a fresh db:schema:load (this test DB) never
# has them. Rather than back a test on their pre-existence, this creates each view
# from db/views and asserts the view SHAPE — every lifecycle timestamp, in logical
# progress order — so a dropped, renamed, or mis-ordered column in the SQL fails
# loudly here instead of in a reviewer's head. Lives in test/db (not test/models)
# because there is no model.
class TimelineViewsTest < ActiveSupport::TestCase
  # The exact projection order the operator reads left-to-right (must match the
  # SELECT lists in db/views verbatim).
  TASK_TIMELINE_COLUMNS = %w[
    slug title stage blocked_at blocked_from blocked_by block_kind
    created_at updated_at started_at
    g1_testing_started_at g1_testing_finished_at g1_failed_at
    submitted_at reviewed_at assembled_at completed_at archived_at
    gates_cached_at testing_phases_cached_at
  ].freeze

  RELEASE_TIMELINE_COLUMNS = %w[
    slug state created_at updated_at
    testing_started_at tested_at
    assembling_started_at assembled_at
    qa_deploy_started_at qa_deployed_at
    confirming_started_at confirmed_at
    prod_deploy_started_at shipped_at
    abandoned_at duration_metrics_cached_at
  ].freeze

  VIEWS = %w[task_timeline release_timeline].freeze

  def view_sql(name) = File.read(Rails.root.join("db/views/#{name}.sql"))

  setup do
    VIEWS.each { |name| ActiveRecord::Base.connection.execute(view_sql(name)) }
  end

  teardown do
    VIEWS.each { |name| ActiveRecord::Base.connection.execute("DROP VIEW IF EXISTS #{name}") }
  end

  test "[integration] the newest migration that creates each view carries the SQL in db/views" do
    VIEWS.each do |name|
      creators = Dir[Rails.root.join("db/migrate/*.rb")].sort.select { |path| File.read(path).include?("CREATE VIEW #{name} AS") }
      up = File.read(creators.last).split(/^\s*def down\b/).first.squish
      assert_includes up, view_sql(name).squish, "#{name}: db/views/#{name}.sql and #{File.basename(creators.last)} differ"
    end
  end

  test "[integration] task_timeline projects the task lifecycle columns in order" do
    columns = ActiveRecord::Base.connection.columns("task_timeline").map(&:name)
    assert_equal TASK_TIMELINE_COLUMNS, columns
  end

  test "[integration] task_timeline carries the full block STATUS HEADER" do
    columns = ActiveRecord::Base.connection.columns("task_timeline").map(&:name)
    # The block set is a status HEADER (sits with slug/title/stage), not a link in
    # the progress chain: Task#clear_block_on_forward_move NULLs all four the moment
    # a task leaves `building`, so they carry values only while it is CURRENTLY
    # blocked. Showing only who+when would say nothing about why or from where.
    assert_equal %w[blocked_at blocked_from blocked_by block_kind],
                 columns & %w[blocked_at blocked_from blocked_by block_kind]
  end

  test "[integration] release_timeline projects the release lifecycle columns in order" do
    columns = ActiveRecord::Base.connection.columns("release_timeline").map(&:name)
    assert_equal RELEASE_TIMELINE_COLUMNS, columns
  end

  test "[integration] release_timeline projects the stage stamps in Release::STAGES order" do
    columns = ActiveRecord::Base.connection.columns("release_timeline").map(&:name)
    stage_columns = Release::STAGES.map { |(_stage, column)| column.to_s }

    # THE contract this view exists to hold: it projects the canonical LOGICAL
    # stage order (Release::STAGES — the same order the /deployments tracker uses),
    # NOT wall-clock. Release stamps deliberately land out of chronological order
    # (assembling_started_at is stamped back at MERGE time, before tested_at), which
    # is exactly why Release#current_stage is MONOTONIC over them. Asserting a
    # chronology here would encode an invariant the system does not hold.
    assert_equal (stage_columns & columns), (columns & stage_columns),
                 "release_timeline must project the stage stamps in Release::STAGES order"
  end

  test "[integration] the views select live rows from their base tables" do
    # A smoke that each view is a real, queryable projection (not just DDL).
    assert_nothing_raised do
      ActiveRecord::Base.connection.select_all("SELECT * FROM task_timeline LIMIT 1")
      ActiveRecord::Base.connection.select_all("SELECT * FROM release_timeline LIMIT 1")
    end
  end
end
