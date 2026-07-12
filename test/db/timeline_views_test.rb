# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260711160000_create_timeline_views.rb").to_s

# The task_timeline / release_timeline views are created by a raw `CREATE VIEW`
# migration that does NOT dump to the :ruby schema, so a fresh db:schema:load
# (this test DB) never has them. Rather than back a test on their pre-existence
# (the caveat), this runs the migration's own up/down and asserts the view SHAPE
# — every lifecycle timestamp, in logical progress order — so a dropped, renamed,
# or mis-ordered column in the CREATE VIEW SQL fails loudly here instead of in a
# reviewer's head. Lives in test/db (not test/models) because there is no model.
class TimelineViewsTest < ActiveSupport::TestCase
  # The exact projection order the operator reads left-to-right (must match the
  # migration's SELECT lists verbatim).
  TASK_TIMELINE_COLUMNS = %w[
    slug title stage blocked_at blocked_from blocked_by block_kind
    created_at updated_at
    queued_at sizes_revealed_at started_at
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
    abandoned_at release_notes_sent_at duration_metrics_cached_at
  ].freeze

  setup do
    @migration = CreateTimelineViews.new
    @migration.verbose = false
    @migration.up
  end

  teardown do
    @migration.down
  end

  test "[integration] task_timeline projects the task lifecycle columns in order" do
    columns = ActiveRecord::Base.connection.columns("task_timeline").map(&:name)
    assert_equal TASK_TIMELINE_COLUMNS, columns
  end

  test "[integration] task_timeline carries the FULL block attribute set" do
    columns = ActiveRecord::Base.connection.columns("task_timeline").map(&:name)
    # `blocked` is an attribute of a building task (blocked_at/_from/_by/kind) —
    # a timeline that showed only who+when would say nothing about why or from
    # where it stalled.
    assert_equal %w[blocked_at blocked_from blocked_by block_kind],
                 columns & %w[blocked_at blocked_from blocked_by block_kind]
  end

  test "[integration] release_timeline projects the release lifecycle columns in order" do
    columns = ActiveRecord::Base.connection.columns("release_timeline").map(&:name)
    assert_equal RELEASE_TIMELINE_COLUMNS, columns
  end

  test "[integration] the views select live rows from their base tables" do
    # A smoke that each view is a real, queryable projection (not just DDL).
    assert_nothing_raised do
      ActiveRecord::Base.connection.select_all("SELECT * FROM task_timeline LIMIT 1")
      ActiveRecord::Base.connection.select_all("SELECT * FROM release_timeline LIMIT 1")
    end
  end
end
