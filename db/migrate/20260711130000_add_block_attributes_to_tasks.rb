class AddBlockAttributesToTasks < ActiveRecord::Migration[7.2]
  # Collapse the `blocked` STAGE into ATTRIBUTES on a `building` task. A block is
  # no longer a board column — it is `blocked_at` (when) + `blocked_from` (where it
  # stalled) + `blocked_by` (who) + `block_kind` (why) carried on a task that sits
  # in `building`. #blocked? re-derives a LIVE block from those columns.
  def up
    add_column :tasks, :blocked_by, :string
    add_column :tasks, :block_kind, :string

    # PROMOTE block_kind out of metadata.devops into its own column (authoritative
    # from here on). The devops copy is left in place on `up` so a rollback can
    # restore it losslessly; new writes go through the column.
    execute(<<~SQL.squish)
      UPDATE tasks
      SET block_kind = metadata #>> '{devops,block_kind}'
      WHERE metadata #>> '{devops,block_kind}' IS NOT NULL
    SQL

    # Backfill blocked_by from the most recent →blocked TaskEvent actor (the agent
    # that raised the block), for tasks still sitting in the retiring stage.
    execute(<<~SQL.squish)
      UPDATE tasks t
      SET blocked_by = e.actor
      FROM (
        SELECT DISTINCT ON (task_slug) task_slug, actor
        FROM task_events
        WHERE to_stage = 'blocked' AND actor IS NOT NULL AND actor <> ''
        ORDER BY task_slug, occurred_at DESC, id DESC
      ) e
      WHERE t.slug = e.task_slug AND t.stage = 'blocked'
    SQL

    # Collapse the stage: every task sitting in `blocked` moves to `building`. It
    # keeps blocked_at/blocked_from/block_kind, so #blocked? (blocked_at present +
    # stage building) re-reads it as a live block — same red card, no lost history.
    # Historical to_stage='blocked' TaskEvents are LEFT intact (the timeline spine).
    execute("UPDATE tasks SET stage = 'building' WHERE stage = 'blocked'")
  end

  def down
    # Best-effort restore: block_kind rides back into metadata.devops, and a task
    # that still carries a live block (blocked_at set while building) returns to the
    # `blocked` stage. blocked_by is dropped (it had no pre-migration home).
    execute(<<~SQL.squish)
      UPDATE tasks
      SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{devops,block_kind}', to_jsonb(block_kind))
      WHERE block_kind IS NOT NULL
    SQL
    execute("UPDATE tasks SET stage = 'blocked' WHERE stage = 'building' AND blocked_at IS NOT NULL")

    remove_column :tasks, :block_kind
    remove_column :tasks, :blocked_by
  end
end
