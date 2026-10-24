# frozen_string_literal: true

# THE ORCHESTRATOR SOUL `xan` IS NOW `ray`. Alex, 2026-10-18: "Please update
# everywhere the name 'Ray' for 'Xan'. That's my middle name and it reads
# better." Step one (RenameXanDisplayNameToRay) moved only the display name; this
# is step two, the key. The seat keeps everything else — its Agent row, its
# history, its grades, its review seats, its chat threads — under the new slug.
# The precedent is RenameAlexSoulToXan (2026-09-24, PR #1579); this follows it
# shape for shape.
#
# WHY DATA MOVES FIRST. The lookups that key on the slug (config/souls.yml,
# ReviewerSelector::POOL, ActionGrade::RAY, DevopsShift::LANES, the dispatcher's
# served souls, the /ray routes) are renamed in the same PR, and a lookup renamed
# ahead of its rows orphans every row it no longer matches. So this migration
# repoints EVERY stored soul-slug value in one transaction, and
# Task::SOUL_ALIASES keeps `xan` (and `alex`) resolving to `ray` for what no
# migration can reach: a sticky session marker, a typed `--actor xan`, a commit
# email `xan@mcritchie.studio`, a dispatcher still claiming for `xan`.
#
# WHAT COUNTS AS A SOUL-SLUG VALUE. Measured against production on 2026-10-18
# (read-only: `WHERE <column> = 'xan'` over every string and jsonb column, and a
# recursive jsonb walk for the paths): COLUMNS, ARRAY_COLUMNS and JSON_KEYS below
# are every surface where `xan` appeared in the soul vocabulary, plus the soul
# columns that held none that day (so a row written before the deploy still
# moves). Left alone, on purpose: task slugs, branches and desk paths that spell
# `xan` (`build-with-xan-intake`), which are names of past work, not soul keys;
# agent_activities reason/outcome slugs (free text); agent_actions.actor, whose
# vocabulary is agent|user; mailbox_drafts.drafted_by (a person); and the
# 1Password items `agent.xan.solana` and `agents.discord.xan`, which live outside
# the database.
#
# IDEMPOTENT — every write is `WHERE value = FROM`, so a second run finds nothing
# and changes nothing. REVERSIBLE — `down` runs the identical repoint the other
# way (it also moves any `ray` written after `up`, which is the only honest
# reverse of a rename). UNIQUE-KEYED rows (a grade, a usage, a skill assignment,
# a shift lane) are repointed only when no target sibling already holds the key;
# a held row is counted in the log, never clobbered.
#
# THE AGENT ROW GOES FIRST. activities, skill_assignments, tasks and usages hold
# real foreign keys to agents.slug, ON UPDATE CASCADE — so on a database with
# only the `xan` row (production) the row is renamed BEFORE the children, and
# Postgres moves those four columns with it; repointing a child first would
# violate its key, because no `ray` row exists yet. When both rows exist (a
# fresh environment seeded under `ray`), the children are repointed onto the
# `ray` row and the source row, now an empty shell, is deleted — by SQL, never
# `destroy`, because Agent `has_many :activities, dependent: :destroy` would take
# 1,300 rows of history with it — and only if no keyed child still names it. Every write is SQL or a schema shim,
# so studio-engine's Sluggable (which refuses a slug change on update) never runs.
#
# Proof: test/db/rename_xan_soul_to_ray_migration_test.rb.
class RenameXanSoulToRay < ActiveRecord::Migration[8.1]
  FROM = "xan"
  TO = "ray"

  # [table, column, unique_with]. `unique_with` names the OTHER columns of a
  # UNIQUE index the column takes part in (so a repoint never collides); `[]`
  # means the column alone is unique; nil means no unique index.
  #
  # `agents.slug` is listed for the tally; its write is #rename_agent_row, which
  # runs before the rest (see the header).
  COLUMNS = [
    ["activities", "agent_slug", nil],
    ["usages", "agent_slug", %w[period_date period_type model]],
    ["skill_assignments", "agent_slug", %w[skill_slug]],
    ["tasks", "agent_slug", nil],
    ["tasks", "blocked_by", nil],
    ["task_events", "actor", nil],
    ["action_grades", "grader", %w[agent_action_id agent_activity_id]],
    ["task_grades", "grader", nil],
    ["task_review_claims", "holder_agent", nil],
    ["review_pending_actions", "authorized_by", nil],
    ["agent_activities", "agent", nil],
    ["agent_activities", "supervisor_agent", nil],
    ["devops_shifts", "lane", []],
    ["gate_runs", "actor", nil],
    ["release_events", "actor", nil],
    ["releases", "confirmed_by", nil],
    ["release_conductor_claims", "holder_soul", nil],
    ["desk_records", "actor", nil],
    ["agent_messages", "soul_slug", nil],
    ["agent_message_events", "actor", nil],
    ["agent_proposals", "soul_slug", nil],
    ["agent_person_notes", "soul_slug", nil],
    ["agent_sessions", "soul", nil],
    ["agent_login_requests", "soul", nil],
    ["agents", "slug", []]
  ].freeze

  # Postgres string arrays of soul slugs: [table, column].
  ARRAY_COLUMNS = [
    ["discord_channels", "postable_souls"]
  ].freeze

  # [table, jsonb column, path, shape]. :string — the value itself; :array — a
  # list of slugs; :reviewers — a list of { "slug" => … } entries (the canonical
  # shape Task.normalize_reviewers writes); :deep_key — every value under the key
  # `path.last`, at any depth (the release duration cache nests its actors).
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

  # The seat's portrait moved with the slug (public/agents/ray.webp).
  AVATARS = { "xan" => "/agents/xan.webp", "ray" => "/agents/ray.webp" }.freeze

  # Schema-pinned shims so the data move never depends on the live models (which
  # carry callbacks, validations and a roster this migration must outlive).
  def self.shim(table)
    @shims ||= {}
    @shims[table] ||= Class.new(ActiveRecord::Base) do
      self.table_name = table
      self.inheritance_column = nil
    end
  end

  def up
    repoint(FROM, TO)
    change_column_default :task_grades, :grader, from: FROM, to: TO if grader_default?
  end

  def down
    repoint(TO, FROM)
    change_column_default :task_grades, :grader, from: TO, to: FROM if grader_default?
  end

  # Rows still carrying `value` per surface — the number a deploy log or a handoff
  # quotes: { "tasks.agent_slug" => 52, "tasks.metadata.devops.built_by" => 95, … }.
  # A class method so a test (or a console) can read the same tally the log prints.
  def self.counts(value, connection: ActiveRecord::Base.connection)
    tally = {}
    COLUMNS.each do |table, column, _unique_with|
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

      tally[surface(table, column, path)] =
        candidates(table, column, value).count { |row| holds?(row[column], path, shape, value) }
    end
    tally
  end

  def self.surface(table, column, path) = [table, column, *path].join(".")

  # The text prefilter that keeps a JSON scan cheap: a JSON string value is
  # always quoted, so `%"xan"%` matches every row that can hold the slug and
  # skips the rest. The in-Ruby shape check does the exact match.
  def self.candidates(table, column, value)
    klass = shim(table)
    klass.where("#{klass.connection.quote_column_name(column)}::text LIKE ?", "%#{klass.sanitize_sql_like(%("#{value}"))}%")
  end

  def self.dig(node, path)
    path.inject(node) { |cur, key| cur.is_a?(Hash) ? cur[key] : nil }
  end

  def self.holds?(doc, path, shape, value)
    return deep_values(doc, path.last).include?(value) if shape == :deep_key

    node = dig(doc, path)
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

  # Rewrite one path in a (deep-dup'd) document. Returns the document; the caller
  # compares against the original to decide whether to write.
  def self.rewrite(doc, path, shape, from, to)
    return deep_rewrite(doc, path.last, from, to) if shape == :deep_key
    return (doc.is_a?(Array) ? doc.map { |v| v == from ? to : v } : doc) if path.empty?

    parent = dig(doc, path[0..-2])
    return doc unless parent.is_a?(Hash)

    key = path.last
    node = parent[key]
    case shape
    when :string
      parent[key] = to if node == from
    when :array
      parent[key] = node.map { |v| v == from ? to : v } if node.is_a?(Array)
    when :reviewers
      node.each { |r| r["slug"] = to if r.is_a?(Hash) && r["slug"] == from } if node.is_a?(Array)
    end
    doc
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

  def repoint(from, to)
    before = self.class.counts(from)
    rename_agent_row(from, to)
    COLUMNS.each do |table, column, unique_with|
      repoint_column(table, column, unique_with, from, to) unless table == "agents"
    end
    ARRAY_COLUMNS.each { |table, column| repoint_array(table, column, from, to) }
    retire_duplicate_agent_row(from, to)
    repoint_avatar(from, to)
    JSON_KEYS.each { |table, column, path, shape| repoint_json(table, column, path, shape, from, to) }
    after = self.class.counts(from)

    before.each do |surface, was|
      held = after.fetch(surface, 0)
      note = held.positive? ? " — HELD, a #{to} sibling already owns the key" : ""
      say "#{surface}: #{was} #{from} → #{held} left#{note}"
    end
  end

  # Schema checks and quoting go straight to the connection (not through the
  # migration's method_missing) so the release log carries one line per UPDATE
  # instead of five lines of `-- quote_column_name` noise per surface.
  def repoint_column(table, column, unique_with, from, to)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    t = connection.quote_table_name(table)
    c = connection.quote_column_name(column)
    guard = ""
    if unique_with
      siblings = unique_with.map do |col|
        q = connection.quote_column_name(col)
        " AND b.#{q} IS NOT DISTINCT FROM a.#{q}"
      end.join
      guard = " AND NOT EXISTS (SELECT 1 FROM #{t} b WHERE b.#{c} = #{quote(to)}#{siblings})"
    end
    execute("UPDATE #{t} a SET #{c} = #{quote(to)} WHERE a.#{c} = #{quote(from)}#{guard}")
  end

  def repoint_array(table, column, from, to)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    t = connection.quote_table_name(table)
    c = connection.quote_column_name(column)
    execute("UPDATE #{t} SET #{c} = array_replace(#{c}, #{quote(from)}::varchar, #{quote(to)}::varchar) " \
            "WHERE #{quote(from)} = ANY(#{c})")
  end

  # The tables whose agent_slug is a real foreign key to agents.slug.
  AGENT_KEYED = %w[activities skill_assignments tasks usages].freeze

  # Only `from` on `agents`: rename the row in place; the keyed children cascade.
  def rename_agent_row(from, to)
    return unless connection.table_exists?(:agents)

    execute("UPDATE agents SET slug = #{quote(to)}, updated_at = NOW() WHERE slug = #{quote(from)} " \
            "AND NOT EXISTS (SELECT 1 FROM agents WHERE slug = #{quote(to)})")
  end

  # Both slugs present on `agents` means the seat was seeded under its new slug
  # before this ran (a fresh environment, or a re-seed racing the release). Its
  # children were just repointed above, so the source row is now an empty shell
  # — remove it by SQL (see the header for why not `destroy`). A keyed child the
  # unique guard HELD still names it, so the row stays, and the log says so.
  def retire_duplicate_agent_row(from, to)
    return unless connection.table_exists?(:agents)

    unkeyed = AGENT_KEYED.select { |t| connection.table_exists?(t) }
                         .map { |t| " AND NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)} WHERE agent_slug = #{quote(from)})" }
                         .join
    execute("DELETE FROM agents WHERE slug = #{quote(from)} " \
            "AND EXISTS (SELECT 1 FROM agents WHERE slug = #{quote(to)})#{unkeyed}")
  end

  # Only the stock portrait moves; an avatar someone set by hand is left alone.
  def repoint_avatar(from, to)
    return unless connection.table_exists?(:agents) && connection.column_exists?(:agents, :avatar)

    execute("UPDATE agents SET avatar = #{quote(AVATARS.fetch(to))} " \
            "WHERE slug = #{quote(to)} AND avatar = #{quote(AVATARS.fetch(from))}")
  end

  def repoint_json(table, column, path, shape, from, to)
    return unless connection.table_exists?(table) && connection.column_exists?(table, column)

    self.class.candidates(table, column, from).find_each do |row|
      doc = row[column]
      next unless doc.is_a?(Hash) || doc.is_a?(Array)

      updated = self.class.rewrite(doc.deep_dup, path, shape, from, to)
      row.update_column(column, updated) if updated != doc
    end
  end

  def grader_default?
    connection.table_exists?(:task_grades) &&
      connection.columns(:task_grades).find { |c| c.name == "grader" }&.default.present?
  end

  def quote(value)
    connection.quote(value)
  end
end
