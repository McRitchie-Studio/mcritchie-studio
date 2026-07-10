# frozen_string_literal: true

# Turn-driven activity spans: the derived lifecycle keys each auto-opened span to
# the assistant turn that produced it, so parallel tool calls in one turn share a
# single span and a subagent span can nest under the delegating one.
#
#   * turn_uuid       — the source assistant turn. UNIQUE per session via a PARTIAL
#                       index (manually-narrated spans carry a NULL turn_uuid and must
#                       still allow many-per-session). This is what makes
#                       AgentActivity.open_for_turn! idempotent + race-safe.
#   * parent_span_id  — a subagent span's link to the delegating span (nesting).
#   * transcript_path — the turn's source transcript. Subagents SHARE the parent
#                       session_id but arrive on a DIFFERENT transcript, so this is
#                       the lineage key: sealing is scoped by (session, agent,
#                       transcript_path) so a subagent's turns never seal the parent's.
class AddTurnAndParentToAgentActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_activities, :turn_uuid, :string
    add_column :agent_activities, :parent_span_id, :bigint
    add_column :agent_activities, :transcript_path, :string

    add_index :agent_activities, %i[session_id turn_uuid],
              unique: true,
              where: "turn_uuid IS NOT NULL",
              name: "index_agent_activities_on_session_and_turn"
    add_index :agent_activities, :parent_span_id,
              name: "index_agent_activities_on_parent_span_id"
    add_index :agent_activities, %i[session_id transcript_path],
              name: "index_agent_activities_on_session_and_transcript"
  end
end
