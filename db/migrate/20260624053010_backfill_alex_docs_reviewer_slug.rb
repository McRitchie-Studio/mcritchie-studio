# The Documentation reviewer persona `alex-docs` was folded into the single
# `alex` identity (orchestrator + the pool's docs seat); db/seeds/02_agents.rb
# retires the old Agent row. Rewrite the historical reviewer references so the
# deploy-timeline avatars (StageAgentsHelper#stage_agent_groups, which resolves a
# reviewer slug to its Agent row) and the retro reviewer lists still resolve to
# the surviving `alex` — same soul, accurate history. Idempotent; one-way.
class BackfillAlexDocsReviewerSlug < ActiveRecord::Migration[7.2]
  # Lightweight, schema-pinned shims so the data fix never depends on the live
  # models (which may change). `metadata` is jsonb on both tables.
  class Ev < ActiveRecord::Base
    self.table_name = "task_events"
  end

  class Tk < ActiveRecord::Base
    self.table_name = "tasks"
  end

  def up
    rewrite(Ev) if table_exists?(:task_events)
    rewrite(Tk) if table_exists?(:tasks)
  end

  # One-way: `alex-docs` is retired, so there is nothing to restore.
  def down; end

  private

  # Rewrite metadata["reviewers"][*]["slug"] "alex-docs" → "alex" on rows that
  # mention it. The text LIKE prefilter keeps this cheap; the in-Ruby guard makes
  # it safe against any non-conforming metadata shape.
  def rewrite(klass)
    klass.where("metadata::text LIKE ?", "%alex-docs%").find_each do |row|
      meta = row.metadata
      next unless meta.is_a?(Hash) && meta["reviewers"].is_a?(Array)

      changed = false
      meta["reviewers"].each do |reviewer|
        if reviewer.is_a?(Hash) && reviewer["slug"] == "alex-docs"
          reviewer["slug"] = "alex"
          changed = true
        end
      end

      row.update_column(:metadata, meta) if changed
    end
  end
end
