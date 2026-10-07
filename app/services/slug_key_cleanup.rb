# Clears the rows written before the slug foreign keys that name a slug no parent
# holds, then validates each slug key still NOT VALID. It is the post-deploy step
# of the slug keys (`bin/rails slug_keys:clean`, the task's post_deploy_cmd):
# AddSlugForeignKeys adds the keys NOT VALID, ValidateSlugForeignKeys validates
# every key whose column is already clean, and this cleans and validates the rest.
#
# The cleanup, per the orphan census (docs/agents/archive/audits/slug-orphan-census-2026-10-06.md):
#   * an agent slug that differs from a real agent only by case takes the agent's;
#   * an activity's unknown agent or task handle moves into its metadata
#     (agent_handle, task_handle), and a task's unknown agent handle into its
#     metadata (agent_handle), before the column is cleared;
#   * a desk record's `<app>.sibling` app slug becomes `<app>`;
#   * every other dangling value in a nullable column is cleared.
# A dangling value in a NOT NULL column is not guessed at: it is counted and its
# key left NOT VALID, for a person to resolve.
#
# Idempotent: the keys refuse every new dangling write, so a second run finds
# nothing to clean and nothing to validate. It reports counts only, never values
# (a person's slug is their name). Each statement runs on its own, outside a
# transaction, under a short lock_timeout.
class SlugKeyCleanup
  LOCK_TIMEOUT = "5s".freeze

  # One UPDATE per table, every handle column at once, so clearing one dangling
  # column never re-checks a row whose other column still dangles.
  HANDLES = {
    "activities" => [%w[agent_slug agents agent_handle], %w[task_slug tasks task_handle]],
    "tasks" => [%w[agent_slug agents agent_handle]]
  }.freeze
  AGENT_COLUMNS = [%w[activities agent_slug], %w[tasks agent_slug], %w[usages agent_slug],
                   %w[skill_assignments agent_slug]].freeze

  Report = Struct.new(:counts, :validated, :left_not_valid, keyword_init: true) do
    def lines
      counts.map { |name, rows| "#{name}: #{rows}" } +
        validated.map { |name| "validated #{name}" } +
        left_not_valid.map { |name, why| "NOT VALID #{name}: #{why}" }
    end
  end

  def initialize(connection: ActiveRecord::Base.connection)
    @db = connection
  end

  def run
    counts = {}
    with_lock_timeout do
      normalise_agent_case(counts)
      move_handles_into_metadata(counts)
      map_sibling_desk_apps(counts)
      validated = []
      left = {}
      self.class.unvalidated_slug_keys(@db).each do |key|
        name = "#{key["child"]}.#{key["column"]}"
        if key["nullable"]
          rows = clear(key)
          counts["#{name} dangling cleared"] = rows if rows.positive?
        elsif (rows = orphan_count(key)).positive?
          left[name] = "#{rows} rows name no #{key["parent"]} row in a NOT NULL column"
          next
        end
        @db.execute("ALTER TABLE #{@db.quote_table_name(key["child"])} VALIDATE CONSTRAINT #{@db.quote_column_name(key["name"])}")
        validated << name
      end
      Report.new(counts: counts, validated: validated, left_not_valid: left)
    end
  end

  # Every slug key (ON UPDATE CASCADE, to a parent's `slug`) not yet validated.
  def self.unvalidated_slug_keys(db)
    db.select_all(<<~SQL.squish).to_a.map { |key| key.merge("nullable" => ActiveModel::Type::Boolean.new.cast(key["nullable"])) }
      SELECT con.conname AS name, child.relname AS child, attr.attname AS column,
             parent.relname AS parent, NOT attr.attnotnull AS nullable
      FROM pg_constraint con
      JOIN pg_class child ON child.oid = con.conrelid
      JOIN pg_class parent ON parent.oid = con.confrelid
      JOIN pg_attribute attr ON attr.attrelid = con.conrelid AND attr.attnum = con.conkey[1]
      JOIN pg_attribute pattr ON pattr.attrelid = con.confrelid AND pattr.attnum = con.confkey[1]
      WHERE con.contype = 'f' AND NOT con.convalidated AND con.confupdtype = 'c'
        AND pattr.attname = 'slug' AND array_length(con.conkey, 1) = 1
      ORDER BY child.relname, attr.attname
    SQL
  end

  def self.orphan_sql(db, child, column, parent)
    c = db.quote_column_name(column)
    "#{c} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #{db.quote_table_name(parent)} p " \
      "WHERE p.slug = #{db.quote_table_name(child)}.#{c})"
  end

  private

  def orphan_sql(child, column, parent) = self.class.orphan_sql(@db, child, column, parent)

  def orphan_count(key)
    @db.select_value("SELECT COUNT(*) FROM #{@db.quote_table_name(key["child"])} " \
                     "WHERE #{orphan_sql(key["child"], key["column"], key["parent"])}").to_i
  end

  def normalise_agent_case(counts)
    AGENT_COLUMNS.each do |table, column|
      c = @db.quote_column_name(column)
      rows = @db.update(<<~SQL.squish)
        UPDATE #{@db.quote_table_name(table)} SET #{c} = lower(#{c})
        WHERE #{c} <> lower(#{c}) AND EXISTS (SELECT 1 FROM agents a WHERE a.slug = lower(#{table}.#{c}))
      SQL
      counts["#{table}.#{column} case-normalised"] = rows if rows.positive?
    end
  end

  def move_handles_into_metadata(counts)
    HANDLES.each do |table, columns|
      kept = columns.map do |column, parent, key|
        "CASE WHEN #{orphan_sql(table, column, parent)} " \
          "THEN jsonb_build_object(#{@db.quote(key)}, #{@db.quote_column_name(column)}) ELSE '{}'::jsonb END"
      end
      cleared = columns.map do |column, parent, _key|
        c = @db.quote_column_name(column)
        "#{c} = CASE WHEN #{orphan_sql(table, column, parent)} THEN NULL ELSE #{c} END"
      end
      rows = @db.update(<<~SQL.squish)
        UPDATE #{@db.quote_table_name(table)}
        SET metadata = COALESCE(metadata, '{}'::jsonb) || #{kept.join(" || ")}, #{cleared.join(", ")}
        WHERE #{columns.map { |column, parent, _| "(#{orphan_sql(table, column, parent)})" }.join(" OR ")}
      SQL
      counts["#{table} handles moved into metadata"] = rows if rows.positive?
    end
  end

  def map_sibling_desk_apps(counts)
    rows = @db.update(<<~SQL.squish)
      UPDATE desk_records SET app_slug = left(app_slug, -length('.sibling'))
      WHERE app_slug LIKE '%.sibling'
        AND EXISTS (SELECT 1 FROM apps a WHERE a.slug = left(desk_records.app_slug, -length('.sibling')))
    SQL
    counts["desk_records.app_slug sibling mapped"] = rows if rows.positive?
  end

  def clear(key)
    c = @db.quote_column_name(key["column"])
    @db.update("UPDATE #{@db.quote_table_name(key["child"])} SET #{c} = NULL " \
               "WHERE #{orphan_sql(key["child"], key["column"], key["parent"])}")
  end

  def with_lock_timeout
    @db.execute("SET lock_timeout = '#{LOCK_TIMEOUT}'")
    yield
  ensure
    @db.execute("RESET lock_timeout") unless @db.transaction_open?
  end
end
