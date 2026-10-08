require "test_helper"
require Rails.root.join("db/migrate/20261008150000_add_state_checks")

# [unit] StringStates is the one list of state columns: each registered column's
# model validates against the registered constant, its CHECK constraint holds the
# same values and is validated, the migration's frozen copy equals the constants,
# and every stage, status or state string column is registered or listed with
# its reason.
class StateCheckConstraintsTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection

  # Each registered column whose constraint is missing, NOT VALID, or holds
  # another list than its constant.
  def constraint_problems
    StateCheckConstraints.new.census.rows.reject { |row| row.state == :valid }.map { |row| "#{row.name}: #{row.state}" }
  end

  # The column's stored constraint definition, rebuilt on a one-column temporary
  # table, so each constraint is exercised whether or not its table holds a row.
  def with_probe(column)
    definition = connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid = #{connection.quote(column.table)}::regclass AND conname = #{connection.quote(column.constraint)}
    SQL
    col = connection.quote_column_name(column.column)
    connection.execute "CREATE TEMP TABLE state_probe AS SELECT #{col} FROM #{connection.quote_table_name(column.table)} WITH NO DATA"
    connection.execute "ALTER TABLE state_probe ADD CONSTRAINT probe #{definition}"
    yield ->(value) { ActiveRecord::Base.transaction(requires_new: true) { connection.execute "INSERT INTO state_probe VALUES (#{connection.quote(value)})" } }
  ensure
    connection.execute "DROP TABLE IF EXISTS state_probe"
  end

  test "[unit] registry_matches_pg_constraint: every registered column has a validated CHECK holding its list" do
    assert_empty constraint_problems
  end

  test "[unit] control: a value in Task::STAGES alone reads as a mismatch" do
    stub_const(Task, :STAGES, (Task::STAGES + %w[limbo]).freeze) do
      assert_equal [ "tasks.stage: differs" ], constraint_problems
    end
  end

  test "[unit] the migration's frozen lists equal the models' constants" do
    assert_equal StringStates.columns.to_h { |column| [ column.name, column.values ] }, AddStateChecks::CHECKS
  end

  test "[integration] each constraint refuses a value outside its list and takes every listed value and NULL" do
    StringStates.columns.each do |column|
      with_probe(column) do |insert|
        assert_raises(ActiveRecord::CheckViolation, column.name) { insert.call("no-such-#{column.column}") }
        (column.values + [ nil ]).each { |value| insert.call(value) }
        assert_equal column.values.size + 1, connection.select_value("SELECT COUNT(*) FROM state_probe"), column.name
      end
    end
  end

  test "[integration] a raw write to a live row is refused outside the list and lands inside it" do
    task = tasks(:new_task)
    write = ->(attributes) { ActiveRecord::Base.transaction(requires_new: true) { Task.where(id: task.id).update_all(attributes) } }

    assert_raises(ActiveRecord::CheckViolation) { write.call(stage: "blocked") }
    assert_raises(ActiveRecord::CheckViolation) { write.call(block_kind: "mood") }
    assert_raises(ActiveRecord::NotNullViolation) { write.call(stage: nil) }
    assert_equal 1, write.call(stage: "building", block_kind: "rework")
    assert_equal "designed", Task.column_defaults["stage"]
  end

  def inclusion_list(column)
    validator = column.model.validators_on(column.column).grep(ActiveModel::Validations::InclusionValidator).first
    validator&.options&.fetch(:in)
  end

  def state_columns
    connection.tables.sort.flat_map do |table|
      connection.columns(table).select { |c| c.type == :string && c.name.match?(StringStates::COLUMN_NAME) }
                .map { |c| "#{table}.#{c.name}" }
    end
  end

  test "[unit] each registered column's validation reads the registered constant" do
    problems = StringStates.columns.filter_map do |column|
      next "#{column.name}: #{column.model} is not the model of #{column.table}" unless column.model.table_name == column.table

      list = inclusion_list(column)
      next "#{column.name}: no inclusion validation" unless list

      "#{column.name}: validates #{list.inspect}, registry says #{column.values.inspect}" unless list.equal?(column.values)
    end

    assert_empty problems
  end

  test "[unit] every stage, status and state string column is registered or listed with a reason" do
    known = StringStates::REGISTRY.keys + StringStates::UNCONSTRAINED.keys

    assert_empty state_columns - known, "a state column with no entry in StringStates"
    assert_empty StringStates::UNCONSTRAINED.keys - state_columns, "StringStates::UNCONSTRAINED names a column that is gone"
    assert_empty StringStates::REGISTRY.keys & StringStates::UNCONSTRAINED.keys
    assert StringStates::UNCONSTRAINED.values.all?(&:present?)
  end
end
