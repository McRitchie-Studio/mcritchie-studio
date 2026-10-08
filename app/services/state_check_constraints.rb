# The state CHECK constraints against the live rows (StringStates is the list).
#
# `census` is read-only by construction: every statement is a SELECT, no
# transaction is opened, and the whole run sits inside
# `ActiveRecord::Base.while_preventing_writes`, so a write raises instead of
# landing. test/services/state_check_census_test.rb measures that over a
# full run. It prints values and counts, never a row.
#
# `apply` finishes what the migrations left: it adds a missing constraint NOT
# VALID and validates a NOT VALID one, for each column whose rows all hold a
# listed value, and makes tasks.stage NOT NULL once no row holds NULL. A column
# with a stray value is left alone and reported: Postgres checks a NOT VALID
# constraint on every later UPDATE of a row, so adding one over a stray value
# would make that row unsaveable. Idempotent; the same locks as the migrations
# (db/migrate/*_add_state_checks.rb, *_validate_state_checks.rb).
class StateCheckConstraints
  LOCK_TIMEOUT = "5s".freeze
  STAGE_PRESENT = "tasks_stage_present".freeze
  VALUE_LIMIT = 20

  # state: :valid, :not_valid, :missing or :differs (the constraint holds another
  # list than the model). strays: { value => rows } outside the list.
  Row = Struct.new(:column, :state, :strays, keyword_init: true) do
    def name = column.name
    def clean? = strays.empty?
    def settled? = state == :valid && clean?
  end

  Census = Struct.new(:rows, :null_stages, :stage_nullable, :unconstrained, :divergent_devops, keyword_init: true) do
    def unsettled = rows.reject(&:settled?)
    def settled? = unsettled.empty? && !stage_nullable

    def lines
      out = rows.map do |row|
        strays = row.strays.map { |value, count| "#{value.to_s.truncate(40).inspect} x#{count}" }.join(", ")
        "#{row.name}: #{row.state.to_s.tr("_", " ")}#{" · outside the list: #{strays}" if strays.present?}"
      end
      out << "tasks.stage: #{stage_nullable ? "nullable" : "NOT NULL"} · NULL rows: #{null_stages}"
      out << "tasks devops keys that differ from their column: #{divergent_devops} rows"
      out << "columns with no CHECK (#{unconstrained.size}), the values each holds:"
      unconstrained.each do |name, values|
        out << "  #{name}: #{values.map { |value, count| "#{value.to_s.truncate(40).inspect} x#{count}" }.join(", ").presence || "no rows"}"
      end
      out
    end
  end

  def initialize(connection: ActiveRecord::Base.connection)
    @connection = connection
  end

  def census
    ActiveRecord::Base.while_preventing_writes do
      Census.new(
        rows: StringStates.columns.map { |column| Row.new(column: column, state: state_of(column), strays: strays(column)) },
        null_stages: @connection.select_value("SELECT COUNT(*) FROM tasks WHERE stage IS NULL").to_i,
        stage_nullable: stage_nullable?,
        unconstrained: StringStates::UNCONSTRAINED.keys.index_with { |name| value_counts(*name.split(".")) },
        divergent_devops: @connection.select_value(TaskDevopsColumnsBackfillJob.divergent.select("COUNT(*)").to_sql).to_i
      )
    end
  end

  # Add and validate every constraint whose column is clean; returns the census
  # as it stands afterwards.
  def apply
    @connection.execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    census.rows.select(&:clean?).each do |row|
      add(row.column) if row.state == :missing
      validate(row.column) if %i[missing not_valid].include?(row.state)
    end
    require_task_stage
    census
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::CheckViolation => e
    Rails.logger.warn("[state-checks] stopped: #{e.class}")
    census
  ensure
    @connection.execute "RESET lock_timeout"
  end

  # The values a constraint holds, read back from its definition.
  def constraint_values(column)
    definition = @connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE contype = 'c' AND conrelid = #{@connection.quote(column.table)}::regclass
        AND conname = #{@connection.quote(column.constraint)}
    SQL
    definition&.scan(/'((?:[^']|'')*)'/)&.flatten
  end

  private

  def state_of(column)
    values = constraint_values(column)
    return :missing unless values
    return :differs unless values.sort == column.values.sort

    validated?(column.table, column.constraint) ? :valid : :not_valid
  end

  def validated?(table, constraint)
    @connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE contype = 'c' AND conrelid = #{@connection.quote(table)}::regclass AND conname = #{@connection.quote(constraint)}
    SQL
  end

  def stage_nullable?
    @connection.select_value("SELECT NOT attnotnull FROM pg_attribute " \
                             "WHERE attrelid = 'tasks'::regclass AND attname = 'stage'")
  end

  def list_sql(column) = column.values.map { |value| @connection.quote(value) }.join(", ")

  def strays(column)
    col = @connection.quote_column_name(column.column)
    @connection.select_rows("SELECT #{col}, COUNT(*) FROM #{@connection.quote_table_name(column.table)} " \
                            "WHERE #{col} IS NOT NULL AND #{col} NOT IN (#{list_sql(column)}) " \
                            "GROUP BY #{col} ORDER BY #{col} LIMIT #{VALUE_LIMIT}").to_h
  end

  def value_counts(table, column)
    col = @connection.quote_column_name(column)
    @connection.select_rows("SELECT #{col}, COUNT(*) FROM #{@connection.quote_table_name(table)} " \
                            "WHERE #{col} IS NOT NULL GROUP BY #{col} ORDER BY COUNT(*) DESC, #{col} LIMIT #{VALUE_LIMIT}").to_h
  end

  def add(column)
    @connection.execute "ALTER TABLE #{@connection.quote_table_name(column.table)} " \
                        "ADD CONSTRAINT #{@connection.quote_column_name(column.constraint)} " \
                        "CHECK (#{@connection.quote_column_name(column.column)} IN (#{list_sql(column)})) NOT VALID"
  end

  def validate(column)
    @connection.execute "ALTER TABLE #{@connection.quote_table_name(column.table)} " \
                        "VALIDATE CONSTRAINT #{@connection.quote_column_name(column.constraint)}"
  end

  def require_task_stage
    return unless stage_nullable?
    return if @connection.select_value("SELECT COUNT(*) FROM tasks WHERE stage IS NULL").to_i.positive?

    @connection.execute "ALTER TABLE tasks DROP CONSTRAINT IF EXISTS #{STAGE_PRESENT}"
    @connection.execute "ALTER TABLE tasks ADD CONSTRAINT #{STAGE_PRESENT} CHECK (stage IS NOT NULL) NOT VALID"
    @connection.execute "ALTER TABLE tasks VALIDATE CONSTRAINT #{STAGE_PRESENT}"
    @connection.execute "ALTER TABLE tasks ALTER COLUMN stage SET NOT NULL"
    @connection.execute "ALTER TABLE tasks DROP CONSTRAINT #{STAGE_PRESENT}"
  end
end
