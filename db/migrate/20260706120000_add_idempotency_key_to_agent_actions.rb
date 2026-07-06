# frozen_string_literal: true

# AgentAction gains the same idempotency_key the other telemetry writes already
# carry (ReleaseEvent, TaskEvent, ReviewEvent) so a source that RE-READS the same
# verdict can dedupe. The first such source is CI ingestion (bin/ci-scope-capture):
# re-reading a PR's checks (dor-check / preflight run twice) must NOT create a
# second row for the same (pr, headSha, job). The key is self-scoping
# (ci:<pr>:<sha>:<job>), so a PARTIAL UNIQUE index over the non-null keys is the
# hard guard; AgentAction.capture also find-firsts on it to skip the create.
class AddIdempotencyKeyToAgentActions < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_actions, :idempotency_key, :string
    add_index :agent_actions, :idempotency_key,
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "index_agent_actions_on_idempotency_key"
  end
end
