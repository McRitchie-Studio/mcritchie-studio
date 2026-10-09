require "test_helper"
require "rake"

# [integration] The slug foreign keys against the census: every resolved column
# carries a validated key to its parent's slug with ON UPDATE CASCADE, or is
# listed in SlugCensus::UNCONSTRAINED with its reason; and the cleanup resolves
# orphans the way the census reading asked.
class SlugForeignKeysTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection
  def census = SlugCensus.new

  def resolved
    census.slug_columns.filter_map do |table, column|
      target_table, target_column, via = census.resolve(table, column)
      ["#{table}.#{column}", table, column, target_table, target_column] unless via == :unresolved
    end
  end

  def key_for(table, column)
    connection.foreign_keys(table).find { |key| key.column == column }
  end

  def validated?(table, column)
    connection.select_value(<<~SQL.squish)
      SELECT con.convalidated FROM pg_constraint con
      JOIN pg_attribute attr ON attr.attrelid = con.conrelid AND attr.attnum = con.conkey[1]
      WHERE con.contype = 'f' AND con.conrelid = #{connection.quote(table)}::regclass
        AND attr.attname = #{connection.quote(column)}
    SQL
  end

  test "[integration] every resolved slug column has a validated ON UPDATE CASCADE key or a listed reason" do
    problems = resolved.filter_map do |name, table, column, target_table, target_column|
      next if SlugCensus::UNCONSTRAINED.key?(name)

      key = key_for(table, column)
      next "#{name}: no foreign key" unless key
      next "#{name}: points at #{key.to_table}.#{key.primary_key}, census says #{target_table}.#{target_column}" unless
        [key.to_table, key.primary_key] == [target_table, target_column]
      next "#{name}: ON UPDATE #{key.on_update.inspect}" unless key.on_update == :cascade
      next "#{name}: ON DELETE RESTRICT, which Rails cannot read as InvalidForeignKey; use NO ACTION" if key.on_delete == :restrict

      "#{name}: still NOT VALID" unless validated?(table, column)
    end

    assert_empty problems
  end

  test "[integration] every listed exception is a resolved column without a key" do
    names = resolved.map(&:first)

    SlugCensus::UNCONSTRAINED.each do |name, reason|
      table, column = name.split(".")
      assert_includes names, name, "#{name} is listed but the census does not resolve it"
      assert_nil key_for(table, column), "#{name} is listed as unconstrained but carries a key"
      assert reason.present?
    end
  end

  test "[integration] a slug change on a non-Sluggable parent cascades in the database" do
    release = Release.create!(slug: "rel-slugkey-cascade", state: Release::STATES.first)
    task = tasks(:new_task)
    task.update_columns(release_slug: release.slug)

    connection.update("UPDATE releases SET slug = 'rel-slugkey-renamed' WHERE id = #{release.id.to_i}")

    assert_equal "rel-slugkey-renamed", task.reload.release_slug
  end

  test "[integration] a write naming a parent that does not exist is refused" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Contract.insert_all!([{ slug: "nobody-buffalo-bills", person_slug: "nobody-on-file", team_slug: teams(:buffalo_bills).slug,
                              contract_type: "active", created_at: Time.current, updated_at: Time.current }])
    end
  end

  # --- the cleanup -----------------------------------------------------------

  # Drops the keys, lets the block write rows that dangle, and puts the keys back
  # NOT VALID, the state a key over dirty rows sits in. DDL is transactional in
  # Postgres, so the test's rollback restores them. All the dangling writes go in
  # one block: Postgres re-checks every key on an UPDATE of a row its own
  # transaction inserted, even when that key did not change.
  def with_keys_not_valid(*keys)
    keys.each { |table, column, parent, _| connection.remove_foreign_key(table, parent, column: column) }
    yield
    keys.each do |table, column, parent, on_delete|
      connection.add_foreign_key(table, parent, column: column, primary_key: "slug", on_update: :cascade,
                                                on_delete: on_delete&.to_sym, validate: false)
    end
  end

  test "[integration] the cleanup validates NOT VALID keys; every census orphan is resolved or listed" do
    note = action = desk = nil
    with_keys_not_valid(["activities", "agent_slug", "agents", nil], %w[activities task_slug tasks nullify],
                        %w[agent_actions task_slug tasks nullify], %w[desk_records app_slug apps nullify],
                        %w[tasks agent_slug agents nullify]) do
      note = Activity.create!(activity_type: "comment", description: "from a mascot")
      note.update_columns(agent_slug: "charmander", task_slug: "live-score-watch")
      action = AgentAction.capture(session_id: "slugkey-session", kind: "tool", summary: "probe")
      assert action, "capture returned nil"
      action.update_columns(task_slug: "codex-stop-hook-cleanup")
      desk = DeskRecord.create!(worktree_path: "/tmp/slugkey-desk", status: DeskRecord::STATUSES.first)
      desk.update_columns(app_slug: "#{apps(:mcritchie_studio).slug}.sibling")
      tasks(:new_task).update_columns(agent_slug: "Xan")
    end

    assert_not validated?("activities", "agent_slug"), "a dirty key sits NOT VALID until the cleanup"
    assert_not validated?("agent_actions", "task_slug")

    report = SlugKeyCleanup.new.run
    assert_empty report.left_not_valid
    assert_includes report.validated, "activities.agent_slug"
    assert report.lines.none? { |line| line.include?("charmander") }, "the report carries counts, never values"

    note.reload
    assert_nil note.agent_slug
    assert_equal "charmander", note.metadata["agent_handle"]
    assert_nil note.task_slug
    assert_equal "live-score-watch", note.metadata["task_handle"]
    assert_nil action.reload.task_slug
    assert_equal apps(:mcritchie_studio).slug, desk.reload.app_slug
    assert_equal "xan", tasks(:new_task).reload.agent_slug
    %w[activities.agent_slug activities.task_slug agent_actions.task_slug desk_records.app_slug tasks.agent_slug].each do |name|
      assert validated?(*name.split(".")), "#{name} is still NOT VALID"
    end
    second = SlugKeyCleanup.new.run
    assert_empty second.counts, "a second run has nothing to clean"
    assert_empty second.validated
  end

  test "[integration] slug_keys:clean prints counts and validates" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("slug_keys:clean")
    Rake::Task["slug_keys:clean"].reenable
    out, = capture_io { Rake::Task["slug_keys:clean"].invoke }

    assert_includes out, "nothing to clean"
  end
end
