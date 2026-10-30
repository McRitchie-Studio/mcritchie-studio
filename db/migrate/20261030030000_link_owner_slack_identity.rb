# Slack (docs/agents/system/agent-message-loop.md, "Slack"): Alex McRitchie's
# Slack user in the McRitchie Studio workspace becomes a `slack` identity of the
# owner's person (found by his Discord id, as LinkOwnerWebIdentities found it),
# so his Slack messages are answered as the owner instead of held. The id is
# config/agent_routes.yml slack.owner_user_id, copied here so the migration
# stands alone. Idempotent; never moves an identity that already belongs to
# someone. AgentPerson.seed_owner! does the same from the config.
class LinkOwnerSlackIdentity < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"
  OWNER_SLACK_ID = "U0CCSMUMQJV"

  class Identity < ActiveRecord::Base
    self.table_name = "agent_person_identities"
  end

  def up
    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    return unless owner
    return if Identity.exists?(platform: "slack", external_id: OWNER_SLACK_ID)

    now = Time.current
    Identity.create!(agent_person_id: owner.agent_person_id, platform: "slack", external_id: OWNER_SLACK_ID,
                     display_name: "Alex McRitchie", created_at: now, updated_at: now)
  end

  def down
    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    return unless owner

    Identity.where(platform: "slack", external_id: OWNER_SLACK_ID, agent_person_id: owner.agent_person_id).delete_all
  end
end
