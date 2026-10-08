require "test_helper"

# [unit] StringStates is the one list of state columns: each registered column's
# model validates against the registered constant, and every stage, status or
# state string column is registered or listed with its reason.
class StateCheckConstraintsTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection

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
