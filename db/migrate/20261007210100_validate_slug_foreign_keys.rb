# Slug foreign keys, step 2 of 2: clean the rows written before step 1 that name a
# slug no parent holds, then VALIDATE each key step 1 added NOT VALID.
#
# Step 1's keys already refuse every new dangling write, so the set cleaned here
# cannot grow while this runs. VALIDATE takes SHARE UPDATE EXCLUSIVE, which does
# not block reads or writes, one key per statement outside a transaction.
#
# The cleanup, per the orphan census (docs/agents/archive/audits/slug-orphan-census-2026-10-06.md):
#   * an agent slug that differs from a real agent only by case takes the agent's;
#   * an activity's unknown agent or task handle moves into its metadata
#     (agent_handle, task_handle), and a task's unknown agent handle into its
#     metadata (agent_handle), before the column is cleared;
#   * a desk record's `<app>.sibling` app slug becomes `<app>`;
#   * every other dangling value in a nullable column is cleared.
# A dangling value in a NOT NULL column is not guessed at: the migration stops and
# names the column and its count, for a person to resolve.
class ValidateSlugForeignKeys < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s".freeze

  def up
    normalise_agent_case
    move_handles_into_metadata
    map_sibling_desk_apps

    pending = unvalidated_slug_keys
    refuse_not_null_orphans(pending)
    pending.each { |key| clear_nullable_orphans(key) }

    execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    pending.each do |key|
      execute "ALTER TABLE #{db.quote_table_name(key["child"])} VALIDATE CONSTRAINT #{db.quote_column_name(key["name"])}"
    end
    execute "RESET lock_timeout"
  end

  # Validation has no inverse worth running: a valid key is also a working NOT
  # VALID one, and step 1's down removes the keys.
  def down; end

  private

  # The connection, called directly so each statement is not echoed as a
  # migration step.
  def db = connection

  # Every slug key (ON UPDATE CASCADE, to a parent's `slug`) not yet validated.
  def unvalidated_slug_keys
    db.select_all(<<~SQL.squish).to_a
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
      .map { |key| key.merge("nullable" => ActiveModel::Type::Boolean.new.cast(key["nullable"])) }
  end

  def orphan_sql(child, column, parent)
    c = db.quote_column_name(column)
    "#{c} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #{db.quote_table_name(parent)} p WHERE p.slug = #{db.quote_table_name(child)}.#{c})"
  end

  def normalise_agent_case
    [%w[activities agent_slug], %w[tasks agent_slug], %w[usages agent_slug], %w[skill_assignments agent_slug]].each do |table, column|
      c = db.quote_column_name(column)
      rows = db.update(<<~SQL.squish)
        UPDATE #{db.quote_table_name(table)} SET #{c} = lower(#{c})
        WHERE #{c} <> lower(#{c}) AND EXISTS (SELECT 1 FROM agents a WHERE a.slug = lower(#{table}.#{c}))
      SQL
      say "#{table}.#{column}: #{rows} case-normalised" if rows.positive?
    end
  end

  # One UPDATE per table, every handle column at once, so clearing one dangling
  # column never re-checks a row whose other column still dangles.
  HANDLES = {
    "activities" => [["agent_slug", "agents", "agent_handle"], ["task_slug", "tasks", "task_handle"]],
    "tasks" => [["agent_slug", "agents", "agent_handle"]]
  }.freeze

  def move_handles_into_metadata
    HANDLES.each do |table, columns|
      kept = columns.map do |column, parent, key|
        "CASE WHEN #{orphan_sql(table, column, parent)} THEN jsonb_build_object(#{db.quote(key)}, #{db.quote_column_name(column)}) ELSE '{}'::jsonb END"
      end
      cleared = columns.map do |column, parent, _key|
        c = db.quote_column_name(column)
        "#{c} = CASE WHEN #{orphan_sql(table, column, parent)} THEN NULL ELSE #{c} END"
      end
      rows = db.update(<<~SQL.squish)
        UPDATE #{db.quote_table_name(table)}
        SET metadata = COALESCE(metadata, '{}'::jsonb) || #{kept.join(" || ")}, #{cleared.join(", ")}
        WHERE #{columns.map { |column, parent, _| "(#{orphan_sql(table, column, parent)})" }.join(" OR ")}
      SQL
      say "#{table}: #{rows} unknown handles moved into metadata" if rows.positive?
    end
  end

  def map_sibling_desk_apps
    rows = db.update(<<~SQL.squish)
      UPDATE desk_records SET app_slug = left(app_slug, -length('.sibling'))
      WHERE app_slug LIKE '%.sibling'
        AND EXISTS (SELECT 1 FROM apps a WHERE a.slug = left(desk_records.app_slug, -length('.sibling')))
    SQL
    say "desk_records.app_slug: #{rows} sibling slugs mapped to their app" if rows.positive?
  end

  def refuse_not_null_orphans(keys)
    found = keys.reject { |key| key["nullable"] }.filter_map do |key|
      count = db.select_value("SELECT COUNT(*) FROM #{db.quote_table_name(key["child"])} WHERE #{orphan_sql(key["child"], key["column"], key["parent"])}").to_i
      "#{key["child"]}.#{key["column"]} (#{count} rows name no #{key["parent"]} row)" if count.positive?
    end
    return if found.empty?

    raise ActiveRecord::MigrationError,
          "slug keys not validated: NOT NULL columns hold dangling slugs: #{found.join("; ")}. " \
          "Run bin/rails db:slug_census, fix or remove those rows, and migrate again."
  end

  def clear_nullable_orphans(key)
    return unless key["nullable"]

    c = db.quote_column_name(key["column"])
    rows = db.update("UPDATE #{db.quote_table_name(key["child"])} SET #{c} = NULL WHERE #{orphan_sql(key["child"], key["column"], key["parent"])}")
    say "#{key["child"]}.#{key["column"]}: #{rows} dangling slugs cleared" if rows.positive?
  end
end
