# frozen_string_literal: true

# THE ORCHESTRATOR SOUL `alex` IS NOW `xan`. The human operator takes the name
# Alex (he was "Mr. McRitchie" in every agent doc), so from here on a soul slug
# reading `alex` would name the owner, not the agent. The seat keeps everything
# else — its Agent row, its history, its grades, its review seats — under the new
# slug. The Solana signing identity `agent.xan.solana` already carried the name
# and is unrelated to this seat; nothing here touches it.
#
# WHY DATA MOVES FIRST. The lookups that key on the slug (Task::SOUL_ROSTER, the
# Agent row, ReviewerSelector::POOL, ActionGrade::XAN, the heartbeat routes) are
# renamed in the same PR, and a lookup renamed ahead of its rows orphans every row
# it no longer matches: an author set naming `alex` excludes nobody from a pool
# that now says `xan`, a grade under `alex` never shows on the Xan heartbeat, a
# task assigned to `alex` points at an Agent that no longer exists. So this
# migration repoints EVERY stored soul-slug value in one transaction, and
# Task::SOUL_ALIASES keeps `alex` resolving to `xan` for one release so a stale
# session marker or a `--actor alex` typed from memory still lands on the seat.
#
# WHAT COUNTS AS A SOUL-SLUG VALUE. Measured against production on 2026-09-24
# (read-only: `WHERE <column> = 'alex'` per column, and `jsonb_each` per metadata
# key): COLUMNS and JSON_KEYS below are every surface where `alex` appeared in the
# soul vocabulary — beside avi, carl, steffon, shannon and jasper (367
# `releases.confirmed_by`, the full-cycle ship authority, among them). Left
# alone, on purpose: users.email / users.name (the human), anything keyed by
# session id, `agent_actions.actor`, whose vocabulary is agent|user, not a
# soul, and `mailbox_drafts.drafted_by`, which names who ASKED for a draft —
# a person, so its two `alex` rows name the operator and stay.
#
# IDEMPOTENT — every write is `WHERE value = FROM`, so a second run finds nothing
# and changes nothing. REVERSIBLE — `down` runs the identical repoint the other
# way (it also moves any `xan` written after `up`, which is the only honest
# reverse of a rename). UNIQUE-KEYED rows (a grade, a usage, a skill assignment,
# a shift lane) are repointed only when no target sibling already holds the key;
# a held row is counted in the log, never clobbered. The Agent row is the one
# exception: two rows for one seat is exactly the state the seed would retire, so
# once its children are repointed a duplicate source row is deleted here — by
# SQL, never `destroy`, because Agent `has_many :activities, dependent: :destroy`
# would take 900+ rows of history with it.
#
# Proof: test/models/rename_alex_soul_to_xan_migration_test.rb.
class RenameAlexSoulToXan < ActiveRecord::Migration[8.1]
  FROM = "alex"
  TO = "xan"

  # [table, column, unique_with]. `unique_with` names the OTHER columns of a
  # UNIQUE index the column takes part in (so a repoint never collides); `[]`
  # means the column alone is unique; nil means no unique index.
  #
  # Rows that hang off the Agent row by slug come FIRST, so the row's own rename
  # at the bottom never strands them (Agent has_many activities / usages /
  # skill_assignments by slug; tasks nullify on destroy — which is why the
  # duplicate-row retirement below is SQL and not a destroy).
  COLUMNS = [
    ["activities", "agent_slug", nil],
    ["usages", "agent_slug", %w[period_date period_type model]],
    ["skill_assignments", "agent_slug", %w[skill_slug]],
    ["tasks", "agent_slug", nil],
    ["tasks", "blocked_by", nil],
    ["task_events", "actor", nil],
    ["action_grades", "grader", %w[agent_action_id agent_activity_id]],
    ["task_review_claims", "holder_agent", nil],
    ["migration_lane_claims", "holder_agent", nil],
    ["review_pending_actions", "authorized_by", nil],
    ["agent_activities", "agent", nil],
    ["agent_activities", "supervisor_agent", nil],
    ["devops_shifts", "lane", []],
    ["gate_runs", "actor", nil],
    ["release_events", "actor", nil],
    ["releases", "confirmed_by", nil],
    ["desk_records", "actor", nil],
    ["agents", "slug", []]
  ].freeze

  # [table, path into `metadata`, shape]. :string — the value itself; :array — a
  # list of slugs; :reviewers — a list of { "slug" => … } entries (the canonical
  # shape Task.normalize_reviewers writes).
  JSON_KEYS = [
    ["tasks", %w[devops built_by], :string],
    ["tasks", %w[devops persona], :string],
    ["tasks", %w[devops approval_requested_by], :string],
    ["tasks", %w[devops builders], :array],
    ["tasks", %w[devops fix_forward], :array],
    ["tasks", %w[reviewers], :reviewers],
    ["task_events", %w[reviewers], :reviewers],
    ["activities", %w[reporter], :string]
  ].freeze

  # Schema-pinned shims so the data move never depends on the live models (which
  # carry callbacks, validations and a roster this migration must outlive).
  # `metadata` is jsonb on all three.
  class Tk < ActiveRecord::Base
    self.table_name = "tasks"
  end

  class Ev < ActiveRecord::Base
    self.table_name = "task_events"
  end

  class Ac < ActiveRecord::Base
    self.table_name = "activities"
  end

  SHIMS = { "tasks" => Tk, "task_events" => Ev, "activities" => Ac }.freeze

  def up
    repoint(FROM, TO)
  end

  def down
    repoint(TO, FROM)
  end

  # Rows still carrying `value` per surface — the number a deploy log or a handoff
  # quotes: { "tasks.agent_slug" => 48, "tasks.metadata.devops.built_by" => 91, … }.
  # A class method so a test (or a console) can read the same tally the log prints.
  def self.counts(value, connection: ActiveRecord::Base.connection)
    tally = {}
    COLUMNS.each do |table, column, _unique_with|
      next unless connection.table_exists?(table) && connection.column_exists?(table, column)

      sql = "SELECT COUNT(*) FROM #{connection.quote_table_name(table)} " \
            "WHERE #{connection.quote_column_name(column)} = #{connection.quote(value)}"
      tally["#{table}.#{column}"] = connection.select_value(sql).to_i
    end
    JSON_KEYS.each do |table, path, shape|
      next unless connection.table_exists?(table)

      tally["#{table}.metadata.#{path.join('.')}"] =
        candidates(SHIMS.fetch(table), value).count { |row| holds?(dig(row.metadata, path), shape, value) }
    end
    tally
  end

  # The text prefilter that keeps a JSON scan cheap: a JSON string value is
  # always quoted, so `%"alex"%` matches every row that can hold the slug and
  # skips the rest. The in-Ruby shape check does the exact match.
  def self.candidates(shim, value)
    shim.where("metadata::text LIKE ?", "%#{shim.sanitize_sql_like(%("#{value}"))}%")
  end

  def self.dig(meta, path)
    path.inject(meta) { |node, key| node.is_a?(Hash) ? node[key] : nil }
  end

  def self.holds?(node, shape, value)
    case shape
    when :string    then node == value
    when :array     then node.is_a?(Array) && node.include?(value)
    when :reviewers then node.is_a?(Array) && node.any? { |r| r.is_a?(Hash) && r["slug"] == value }
    else false
    end
  end

  # Rewrite one path in a (deep-dup'd) metadata hash. Returns the hash; the
  # caller compares against the original to decide whether to write.
  def self.rewrite(meta, path, shape, from, to)
    parent = dig(meta, path[0..-2])
    return meta unless parent.is_a?(Hash)

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
    meta
  end

  private

  def repoint(from, to)
    before = self.class.counts(from)
    COLUMNS.each { |table, column, unique_with| repoint_column(table, column, unique_with, from, to) }
    retire_duplicate_agent_row(from, to)
    JSON_KEYS.each { |table, path, shape| repoint_json(table, path, shape, from, to) }
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

  # Both slugs present on `agents` means the seat was seeded under its new slug
  # before this ran (a fresh environment, or a re-seed racing the release). Its
  # children were just repointed above, so the source row is now an empty shell
  # — remove it by SQL (see the header for why not `destroy`).
  def retire_duplicate_agent_row(from, to)
    return unless connection.table_exists?(:agents)

    execute("DELETE FROM agents WHERE slug = #{quote(from)} AND EXISTS (SELECT 1 FROM agents WHERE slug = #{quote(to)})")
  end

  def repoint_json(table, path, shape, from, to)
    return unless connection.table_exists?(table)

    self.class.candidates(SHIMS.fetch(table), from).find_each do |row|
      meta = row.metadata
      next unless meta.is_a?(Hash)

      updated = self.class.rewrite(meta.deep_dup, path, shape, from, to)
      row.update_column(:metadata, updated) if updated != meta
    end
  end

  def quote(value)
    connection.quote(value)
  end
end
