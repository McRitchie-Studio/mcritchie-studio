# Microsoft Teams conversation references (TeamsConversation): where the bot may
# post on its own (a proactive post needs the serviceUrl and the channel's
# conversation id, which only an activity from that place carries). Written by
# AgentMessages::TeamsIngest from the install conversationUpdate /
# installationUpdate, a channelCreated event, and every message the bot reads.
class CreateTeamsConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :teams_conversations do |t|
      t.string :conversation_id, null: false
      t.string :conversation_type
      t.string :service_url, null: false
      t.string :tenant_id
      t.string :team_id
      t.string :team_name
      t.string :name
      t.string :bot_id
      t.string :installed_by_aad_object_id
      t.string :status, null: false, default: "installed"
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :teams_conversations, :conversation_id, unique: true
    add_index :teams_conversations, :team_id
    add_check_constraint :teams_conversations, "status IN ('installed', 'removed')", name: "teams_conversations_status_known"
  end
end
