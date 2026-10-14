# How many times a message was handed back on a Claude usage limit without
# spending its attempt (AgentMessage#release! code usage_limit). The board caps
# those refunds at AgentMessage::MAX_REFUNDS, so a message can never loop
# forever on refunds: past the cap a usage-limit release spends the attempt and
# dead-letters on the last one, like any other give-back.
class AddUsageRefundsToAgentMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_messages, :usage_refunds, :integer, null: false, default: 0
  end
end
