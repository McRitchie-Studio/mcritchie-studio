# Copies each Task::DEVOPS_MIRRORED_KEYS key from metadata["devops"] into its
# column, for every task whose column disagrees with its key. Task saves keep the
# two equal from then on (Task#mirror_devops_columns); this reaches the rows
# nobody saves again, and the rows old code wrote during a rolling deploy.
#
# Idempotent: it updates only divergent rows, so a second run updates none. The
# key wins, because every writer, old code included, writes the key. Batched by
# primary key, one set-based UPDATE per batch, so each statement locks at most
# BATCH_SIZE rows and reads each row's metadata under its own row lock. It
# touches no updated_at and fires no callbacks or broadcasts, so a historical
# row stays historical.
#
# Driver: `bin/rails tasks:backfill_devops_columns` (the post_deploy_cmd), which
# fails when any row still diverges afterwards.
class TaskDevopsColumnsBackfillJob < ApplicationJob
  BATCH_SIZE = 500
  # The whitespace Ruby's String#strip removes, so the SQL copy and the Ruby
  # mirror agree byte for byte.
  WHITESPACE = "E' \\t\\n\\r\\f\\v'".freeze

  Result = Struct.new(:updated, :divergent, keyword_init: true)

  # The column value a key yields: trimmed, blank as NULL.
  def self.key_expression(key)
    "NULLIF(btrim(tasks.metadata -> 'devops' ->> #{Task.connection.quote(key)}, #{WHITESPACE}), '')"
  end

  # Rows where any mirrored column disagrees with its key.
  def self.divergent
    clauses = Task::DEVOPS_MIRRORED_KEYS.map { |key| "tasks.#{key} IS DISTINCT FROM #{key_expression(key)}" }
    Task.where(clauses.join(" OR "))
  end

  def perform
    assignments = Task::DEVOPS_MIRRORED_KEYS.map { |key| "#{key} = #{self.class.key_expression(key)}" }.join(", ")
    updated = 0
    Task.in_batches(of: BATCH_SIZE) do |batch|
      updated += batch.merge(self.class.divergent).update_all(assignments) # rubocop:disable Rails/SkipsModelValidations
    end
    Result.new(updated: updated, divergent: self.class.divergent.count)
  end
end
