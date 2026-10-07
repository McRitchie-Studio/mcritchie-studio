# Slug foreign keys, step 2 of 2: VALIDATE each key step 1 added NOT VALID whose
# column already holds no dangling slug. It writes no rows.
#
# The rows written before step 1 that name a slug no parent holds are cleaned
# after the deploy, by the task's post_deploy_cmd (`bin/rails slug_keys:clean`,
# SlugKeyCleanup), which then validates the keys this step leaves NOT VALID.
# Step 1's keys already refuse every new dangling write, so that set cannot grow.
#
# A dangling slug in a NOT NULL column has no cleanup to wait for: the migration
# stops and names the column and its count, for a person to resolve.
#
# lock_timeout is set before anything else. VALIDATE takes SHARE UPDATE EXCLUSIVE,
# which blocks neither reads nor writes; one key per statement, outside a
# transaction, so a key that waits too long fails alone and a re-run resumes.
class ValidateSlugForeignKeys < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s".freeze

  def up
    db.execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"

    pending = unvalidated_slug_keys
    refuse_not_null_orphans(pending)
    pending.each do |key|
      name = "#{key["child"]}.#{key["column"]}"
      if (rows = orphan_count(key)).positive?
        say "#{name}: #{rows} dangling rows; left NOT VALID for bin/rails slug_keys:clean"
        next
      end

      db.execute "ALTER TABLE #{db.quote_table_name(key["child"])} VALIDATE CONSTRAINT #{db.quote_column_name(key["name"])}"
    end
    db.execute "RESET lock_timeout"
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

  def orphan_count(key)
    c = db.quote_column_name(key["column"])
    child = db.quote_table_name(key["child"])
    db.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM #{child}
      WHERE #{c} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #{db.quote_table_name(key["parent"])} p WHERE p.slug = #{child}.#{c})
    SQL
  end

  def refuse_not_null_orphans(keys)
    found = keys.reject { |key| key["nullable"] }.filter_map do |key|
      count = orphan_count(key)
      "#{key["child"]}.#{key["column"]} (#{count} rows name no #{key["parent"]} row)" if count.positive?
    end
    return if found.empty?

    raise ActiveRecord::MigrationError,
          "slug keys not validated: NOT NULL columns hold dangling slugs: #{found.join("; ")}. " \
          "Run bin/rails db:slug_census, fix or remove those rows, and migrate again."
  end
end
