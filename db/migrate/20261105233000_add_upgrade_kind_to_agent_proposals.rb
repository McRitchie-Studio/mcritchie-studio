# An upgrade proposal (AgentProposals::Upgrade): Alex asks the owner to move a
# person to a package tier, and the owner approves or declines it on
# /admin/upgrade_proposals. The proposal kinds were ask / operate / change.
class AddUpgradeKindToAgentProposals < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :agent_proposals, name: "agent_proposals_kind_known"
    add_check_constraint :agent_proposals, "kind IN ('ask', 'operate', 'change', 'upgrade')", name: "agent_proposals_kind_known"
  end

  def down
    execute "DELETE FROM agent_proposals WHERE kind = 'upgrade'"
    remove_check_constraint :agent_proposals, name: "agent_proposals_kind_known"
    add_check_constraint :agent_proposals, "kind IN ('ask', 'operate', 'change')", name: "agent_proposals_kind_known"
  end
end
