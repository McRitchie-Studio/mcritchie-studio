# frozen_string_literal: true

# REX FOLDS INTO ALEX. Alex McRitchie, 2026-10-28 (accountability-chart ruling 3):
# "Just roll Rex into Alex. We only need one marketing seat for now." Rex, the
# CMO, is no longer a soul; his method, SOPs and dossiers moved to Alex
# (docs/agents/agents/alex/), and the `rex` slug is an alias of `alex`
# (Task::SOUL_ALIASES). Card: rex-folds-into-alex.
#
# A MERGE, NOT A RENAME. RenameRaySoulToAlex (and RenameXanSoulToRay before it)
# moved ONE seat to a new slug, so its agent row was renamed in place. Here both
# seats already have rows: `alex` keeps its row, and every stored `rex` soul value
# moves onto it. Then the `rex` agent row, an empty shell by then, is removed by
# SQL (never `destroy`: Agent has_many :activities dependent: :destroy).
#
# THE SURFACES are RenameRaySoulToAlex's list, frozen here as of 2026-10-28, minus
# two: `releases.confirmed_by` names the HUMAN (ConfirmedByAlexToAlexMcritchie),
# and the split surfaces (grader, devops lane) never held `rex`: Rex graded
# nothing and held no lane, so there is no split.
#
# THE UNIQUE KEYS. A `rex` row whose `alex` sibling already owns the unique key is
# HELD by the guard, as in the rename. A merge then has to settle it, or the rex
# agent row could never go:
#   skill_assignments  the alex sibling already holds that skill: drop the rex row
#   usages             add the rex row's counters into the alex sibling, then drop it
#   agent_dispatchers  `souls` is an array; a rex entry beside an alex one dedupes
# Any other held row keeps its keyed child, so the rex agent row stays and the
# log says so; the alias still resolves it on read.
#
# NOTHING IS ORPHANED. Board rows authored by `rex` (tasks, activities, spans,
# messages, events) are repointed to `alex`; whatever no migration reaches (a
# sticky session marker, a typed `--agent rex`, a commit from rex@) resolves
# through Task::SOUL_ALIASES and its bin/ mirrors.
#
# IDEMPOTENT: a second run finds no `rex` value and changes nothing.
# IRREVERSIBLE IN DATA: once merged, a moved row is indistinguishable from one
# Alex wrote, so `down` changes nothing and says so (the alias keeps `rex`
# resolving either way). It does not raise, so a schema rollback past it works.
#
# Proof: test/db/merge_rex_soul_into_alex_migration_test.rb.
class MergeRexSoulIntoAlex < ActiveRecord::Migration[8.1]
  FROM = "rex"
  TO = "alex"

  # [table, column, unique_with] — as RenameRaySoulToAlex::COLUMNS.
  COLUMNS = [
    ["activities", "agent_slug", nil],
    ["usages", "agent_slug", %w[period_date period_type model]],
    ["skill_assignments", "agent_slug", %w[skill_slug]],
    ["tasks", "agent_slug", nil],
    ["tasks", "blocked_by", nil],
    ["task_events", "actor", nil],
    ["task_review_claims", "holder_agent", nil],
    ["review_pending_actions", "authorized_by", nil],
    ["agent_activities", "agent", nil],
    ["agent_activities", "supervisor_agent", nil],
    ["gate_runs", "actor", nil],
    ["release_events", "actor", nil],
    ["release_conductor_claims", "holder_soul", nil],
    ["desk_records", "actor", nil],
    ["agent_messages", "soul_slug", nil],
    ["agent_message_events", "actor", nil],
    ["agent_proposals", "soul_slug", nil],
    ["agent_person_notes", "soul_slug", nil],
    ["agent_sessions", "soul", nil],
    ["agent_login_requests", "soul", nil]
  ].freeze

  ARRAY_COLUMNS = [
    ["discord_channels", "postable_souls"]
  ].freeze

  # [table, jsonb column, path, shape] — as RenameRaySoulToAlex::JSON_KEYS.
  JSON_KEYS = [
    ["tasks", "metadata", %w[devops built_by], :string],
    ["tasks", "metadata", %w[devops persona], :string],
    ["tasks", "metadata", %w[devops approval_requested_by], :string],
    ["tasks", "metadata", %w[devops builders], :array],
    ["tasks", "metadata", %w[devops fix_forward], :array],
    ["tasks", "metadata", %w[reviewers], :reviewers],
    ["task_events", "metadata", %w[reviewers], :reviewers],
    ["activities", "metadata", %w[reporter], :string],
    ["activities", "metadata", %w[blocked_by], :string],
    ["agent_dispatchers", "souls", [], :array],
    ["agent_message_events", "detail", %w[soul], :string],
    ["releases", "duration_metrics", %w[actor], :deep_key]
  ].freeze

  # The usage counters a held rex row adds into its alex sibling.
  USAGE_COUNTERS = %w[api_calls cost tasks_completed tasks_failed tokens_in tokens_out].freeze

  # The tables whose agent_slug is a real foreign key to agents.slug.
  AGENT_KEYED = %w[activities skill_assignments tasks usages].freeze

  def self.shim(table)
    @shims ||= {}
    @shims[table] ||= Class.new(ActiveRecord::Base) do
      self.table_name = table
      self.inheritance_column = nil
    end
  end

  def up
    before = self.class.counts(FROM)
    adopt_agent_row
    COLUMNS.each { |table, column, unique_with| repoint_column(table, column, unique_with) }
    settle_held_skills
    settle_held_usages
    ARRAY_COLUMNS.each { |table, column| repoint_array(table, column) }
    JSON_KEYS.each { |table, column, path, shape| repoint_json(table, column, path, shape) }
    retire_agent_row
    after = self.class.counts(FROM)

    before.each do |surface, was|
      held = after.fetch(surface, 0)
      note = held.positive? ? " — HELD, an alex sibling owns the key" : ""
      say "#{surface}: #{was} #{FROM} → #{held} left#{note}"
    end
  end

  def down
    say "MergeRexSoulIntoAlex is a merge: moved rows cannot be told from alex's own, so down changes nothing. " \
        "Task::SOUL_ALIASES keeps `rex` resolving to `alex`."
  end

  # Rows still carrying `value` per surface, `agents.slug` included.
  def self.counts(value, connection: ActiveRecord::Base.connection)
    tally = {}
    (COLUMNS + [["agents", "slug", nil]]).each do |table, column, _|
      next unless connection.table_exists?(table) && connection.column_exists?(table, column)

      sql = "SELECT COUNT(*) FROM #{connection.quote_table_name(table)} " \
            "WHERE #{connection.quote_column_name(column)} = #{connection.quote(value)}"
      tally["#{table}.#{column}"] = connection.select_value(sql).to_i
    end
    ARRAY_COLUMNS.each do |table, column|
      next unless connection.table_exists?(table) && connection.column_exists?(table, column)

      sql = "SELECT COUNT(*) FROM #{connection.quote_table_name(table)} " \
            "WHERE #{connection.quote(value)} = ANY(#{connection.quote_column_name(column)})"
      tally["#{table}.#{column}"] = connection.select_value(sql).to_i
    end
    JSON_KEYS.each do |table, column, path, shape|
      next unless connection.table_exists?(table) && connection.column_exists?(table, column)

      tally[[table, column, *path].join(".")] =
        candidates(table, column, value).count { |row| holds?(row[column], path, shape, value) }
    end
    tally
  end

  def self.candidates(table, column, value)
    klass = shim(table)
    klass.where("#{klass.connection.quote_column_name(column)}::text LIKE ?", "%#{klass.sanitize_sql_like(%("#{value}"))}%")
  end

  def self.dig(node, path)
    path.inject(node) { |cur, key| cur.is_a?(Hash) ? cur[key] : nil }
  end

  def self.holds?(doc, path, shape, value)
    return deep_values(doc, path.last).include?(value) if shape == :deep_key

    node = path.empty? ? doc : dig(doc, path)
    case shape
    when :string    then node == value
    when :array     then node.is_a?(Array) && node.include?(value)
    when :reviewers then node.is_a?(Array) && node.any? { |r| r.is_a?(Hash) && r["slug"] == value }
    else false
    end
  end

  def self.deep_values(node, key)
    case node
    when Hash then node.flat_map { |k, v| (k == key ? [v] : []) + deep_values(v, key) }
    when Array then node.flat_map { |v| deep_values(v, key) }
    else []
    end
  end

  # Rewrite one path in a (deep-dup'd) document. A list that held both slugs keeps
  # ONE `alex` (a merge must not leave an author set naming the seat twice).
  def self.rewrite(doc, path, shape, from, to)
    return deep_rewrite(doc, path.last, from, to) if shape == :deep_key
    return merge_list(doc, from, to) if path.empty?

    parent = dig(doc, path[0..-2])
    return doc unless parent.is_a?(Hash)

    key = path.last
    node = parent[key]
    case shape
    when :string
      parent[key] = to if node == from
    when :array
      parent[key] = merge_list(node, from, to) if node.is_a?(Array)
    when :reviewers
      if node.is_a?(Array) && node.any? { |r| r.is_a?(Hash) && r["slug"] == from }
        node.each { |r| r["slug"] = to if r.is_a?(Hash) && r["slug"] == from }
        parent[key] = first_only(node) { |r| r.is_a?(Hash) && r["slug"] == to }
      end
    end
    doc
  end

  def self.merge_list(list, from, to)
    return list unless list.is_a?(Array) && list.include?(from)

    first_only(list.map { |v| v == from ? to : v }) { |v| v == to }
  end

  # Keep the first element the block matches and drop the later ones; every other
  # element stays where it was.
  def self.first_only(list)
    seen = false
    list.reject do |v|
      next false unless yield(v)

      dup = seen
      seen = true
      dup
    end
  end

  def self.deep_rewrite(node, key, from, to)
    case node
    when Hash
      node.each_key { |k| node[k] = (k == key && node[k] == from) ? to : deep_rewrite(node[k], key, from, to) }
    when Array
      node.map! { |v| deep_rewrite(v, key, from, to) }
    end
    node
  end

  private

  def repoint_column(table, column, unique_with)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    t = connection.quote_table_name(table)
    c = connection.quote_column_name(column)
    guard = ""
    if unique_with
      siblings = unique_with.map do |col|
        q = connection.quote_column_name(col)
        " AND b.#{q} IS NOT DISTINCT FROM a.#{q}"
      end.join
      guard = " AND NOT EXISTS (SELECT 1 FROM #{t} b WHERE b.#{c} = #{quote(TO)}#{siblings})"
    end
    execute("UPDATE #{t} a SET #{c} = #{quote(TO)} WHERE a.#{c} = #{quote(FROM)}#{guard}")
  end

  # A rex skill the alex row already holds is the same assignment twice.
  def settle_held_skills
    return unless connection.table_exists?(:skill_assignments)

    execute("DELETE FROM skill_assignments a WHERE a.agent_slug = #{quote(FROM)} AND EXISTS " \
            "(SELECT 1 FROM skill_assignments b WHERE b.agent_slug = #{quote(TO)} AND b.skill_slug = a.skill_slug)")
  end

  # A rex usage row for a period alex also used: the seat's usage is the sum.
  def settle_held_usages
    return unless connection.table_exists?(:usages)

    counters = USAGE_COUNTERS.select { |col| connection.column_exists?(:usages, col) }
    match = "b.agent_slug = #{quote(FROM)} AND b.period_date = a.period_date AND " \
            "b.period_type = a.period_type AND b.model IS NOT DISTINCT FROM a.model"
    if counters.any?
      sets = counters.map { |col| "#{col} = COALESCE(a.#{col}, 0) + COALESCE(b.#{col}, 0)" }.join(", ")
      execute("UPDATE usages a SET #{sets}, updated_at = NOW() FROM usages b " \
              "WHERE a.agent_slug = #{quote(TO)} AND #{match}")
    end
    execute("DELETE FROM usages b WHERE b.agent_slug = #{quote(FROM)} AND EXISTS " \
            "(SELECT 1 FROM usages a WHERE a.agent_slug = #{quote(TO)} AND a.period_date = b.period_date " \
            "AND a.period_type = b.period_type AND a.model IS NOT DISTINCT FROM b.model)")
  end

  def repoint_array(table, column)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    t = connection.quote_table_name(table)
    c = connection.quote_column_name(column)
    # Drop rex where alex is already listed; replace it where alex is not.
    execute("UPDATE #{t} SET #{c} = array_remove(#{c}, #{quote(FROM)}::varchar) " \
            "WHERE #{quote(FROM)} = ANY(#{c}) AND #{quote(TO)} = ANY(#{c})")
    execute("UPDATE #{t} SET #{c} = array_replace(#{c}, #{quote(FROM)}::varchar, #{quote(TO)}::varchar) " \
            "WHERE #{quote(FROM)} = ANY(#{c})")
  end

  def repoint_json(table, column, path, shape)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    self.class.candidates(table, column, FROM).find_each do |row|
      doc = row[column]
      next unless doc.is_a?(Hash) || doc.is_a?(Array)

      updated = self.class.rewrite(doc.deep_dup, path, shape, FROM, TO)
      row.update_column(column, updated) if updated != doc
    end
  end

  # FIRST, before any keyed child moves: with no alex row (a database never seeded
  # with the persona) the rex row is renamed in place, so the children's foreign
  # keys always have a target and the seat's history is never lost.
  def adopt_agent_row
    return unless connection.table_exists?(:agents)

    execute("UPDATE agents SET slug = #{quote(TO)}, updated_at = NOW() WHERE slug = #{quote(FROM)} " \
            "AND NOT EXISTS (SELECT 1 FROM agents WHERE slug = #{quote(TO)})")
  end

  # LAST: the rex agent row goes once nothing keyed still names it.
  def retire_agent_row
    return unless connection.table_exists?(:agents)

    unkeyed = AGENT_KEYED.select { |t| connection.table_exists?(t) }
                         .map { |t| " AND NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)} WHERE agent_slug = #{quote(FROM)})" }
                         .join
    execute("DELETE FROM agents WHERE slug = #{quote(FROM)}#{unkeyed}")
  end

  def quote(value)
    connection.quote(value)
  end
end
