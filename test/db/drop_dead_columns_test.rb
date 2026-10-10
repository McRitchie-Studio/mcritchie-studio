# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261009200000_drop_dead_columns.rb")

# [unit] The dropped columns are gone from the schema and from every model, and the
# migration runs both ways: `down` rebuilds each column's definition, the index and
# the earlier views; `up` drops them again and leaves both timeline views readable.
class DropDeadColumnsTest < ActiveSupport::TestCase
  # table => column => [sql type, default]
  DROPPED = {
    "tasks" => { "error_message" => [ "text", nil ], "failed_at" => [ "timestamp(6) without time zone", nil ],
                 "queued_at" => [ "timestamp(6) without time zone", nil ], "required_skills" => [ "jsonb", "[]" ],
                 "sizes_revealed_at" => [ "timestamp(6) without time zone", nil ] },
    "releases" => { "release_notes_sent_at" => [ "timestamp(6) without time zone", nil ] },
    "github_workflow_runs" => { "pending_environment" => [ "character varying", nil ],
                                "pending_since" => [ "timestamp(6) without time zone", nil ] },
    "teams" => { "logo_path" => [ "character varying", nil ], "logo_source" => [ "character varying", nil ],
                 "logo_url" => [ "character varying", nil ] },
    "skill_assignments" => { "proficiency" => [ "integer", "100" ] }
  }.freeze
  MODELS = { "tasks" => Task, "releases" => Release, "github_workflow_runs" => GithubWorkflowRun,
             "teams" => Team, "skill_assignments" => SkillAssignment }.freeze
  INDEX = "index_github_workflow_runs_on_pending_environment"
  VIEW_ONLY = { "task_timeline" => %w[queued_at sizes_revealed_at], "release_timeline" => %w[release_notes_sent_at] }.freeze

  setup do
    @connection = ActiveRecord::Base.connection
    @migration = DropDeadColumns.new.tap { |migration| migration.verbose = false }
  end

  def held(table) = @connection.columns(table).to_h { |column| [ column.name, column ] }

  def assert_dropped
    DROPPED.each { |table, columns| assert_empty columns.keys & held(table).keys, "#{table} holds a dropped column" }
    assert_not @connection.index_name_exists?("github_workflow_runs", INDEX)
  end

  test "[unit] the schema, the migration and the models agree: none of the dropped columns remains" do
    assert_equal 12, DROPPED.values.sum(&:size)
    assert_equal DROPPED.transform_values { |columns| columns.keys.sort },
                 DbBaseline.removed_columns(Rails.root.join("db/migrate")).transform_values(&:sort).slice(*DROPPED.keys)
    assert_dropped
    schema = File.read(Rails.root.join("db/schema.rb"))
    DROPPED.each do |table, columns|
      block = schema[/^  create_table "#{table}".*?^  end$/m]
      columns.each_key { |column| assert_no_match(/"#{column}"/, block, "db/schema.rb #{table}.#{column}") }
      assert_empty MODELS.fetch(table).ignored_columns & columns.keys, "#{table}: a dropped column needs no ignore"
    end
    assert_includes held("tasks").keys, "stage", "control: a live column is read"
  end

  test "[integration] down restores every column, the index and the earlier views; up drops them and both views read" do
    @migration.down

    DROPPED.each do |table, columns|
      now = held(table)
      columns.each do |name, (type, default)|
        column = now.fetch(name) { flunk "down did not restore #{table}.#{name}" }
        assert_equal type, column.sql_type, "#{table}.#{name} type"
        assert_nil_or_equal default, column.default, "#{table}.#{name} default"
        assert column.null, "#{table}.#{name} is nullable"
      end
    end
    index = @connection.indexes("github_workflow_runs").find { |candidate| candidate.name == INDEX }
    assert_equal [ "pending_environment" ], index.columns
    assert_equal "(pending_environment IS NOT NULL)", index.where
    VIEW_ONLY.each { |view, columns| assert_equal columns, columns & @connection.columns(view).map(&:name), "#{view} after down" }

    @migration.up

    assert_dropped
    VIEW_ONLY.each do |view, columns|
      assert_empty columns & @connection.columns(view).map(&:name), "#{view} after up"
      projected = File.read(Rails.root.join("db/views/#{view}.sql"))[/SELECT(.*)FROM/m, 1].split(",").map(&:strip)
      assert_equal projected, @connection.columns(view).map(&:name), "#{view} projects db/views"
    end
    Task.reset_column_information
    Release.reset_column_information
    task = Task.create!(title: "Timeline Probe", stage: "designed")
    release = Release.create!(slug: "rel-timeline-probe", state: "assembling")
    assert_equal task.slug, @connection.select_value("SELECT slug FROM task_timeline WHERE slug = #{@connection.quote(task.slug)}")
    assert_equal release.slug, @connection.select_value("SELECT slug FROM release_timeline WHERE slug = #{@connection.quote(release.slug)}")
  ensure
    @connection.execute("DROP VIEW IF EXISTS task_timeline")
    @connection.execute("DROP VIEW IF EXISTS release_timeline")
  end

  private

  def assert_nil_or_equal(expected, actual, message)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual.to_s, message)
  end
end
