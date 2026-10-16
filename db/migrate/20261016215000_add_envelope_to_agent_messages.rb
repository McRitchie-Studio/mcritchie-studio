# Email reaches the agent mailbox (docs/agents/system/agent-message-loop.md,
# "Email"). An email row keeps its envelope (from, to, cc, subject, Message-ID,
# In-Reply-To, References, the trust verdict, the desk item) for the threaded
# reply; a Discord row leaves it empty.
#
# Alex's alex@mcritchie.studio becomes an `email` identity of the owner's person
# (found by his Discord id, as AddRoleToAgentPeople found it), so a VERIFIED mail
# from him is answered as the owner. Idempotent, and it never moves an identity
# that already belongs to someone. AgentPerson.seed_owner! does the same.
class AddEnvelopeToAgentMessages < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"
  OWNER_EMAIL = "alex@mcritchie.studio"

  class Identity < ActiveRecord::Base
    self.table_name = "agent_person_identities"
  end

  def up
    add_column :agent_messages, :envelope, :jsonb, null: false, default: {}

    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    return unless owner
    return if Identity.exists?(platform: "email", external_id: OWNER_EMAIL)

    now = Time.current
    Identity.create!(agent_person_id: owner.agent_person_id, platform: "email", external_id: OWNER_EMAIL,
                     display_name: "Alex", created_at: now, updated_at: now)
  end

  def down
    remove_column :agent_messages, :envelope
  end
end
