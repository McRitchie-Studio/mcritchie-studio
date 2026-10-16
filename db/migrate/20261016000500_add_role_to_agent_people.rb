# The audience of an agent mailbox answer (docs/agents/modules/agent-communication.md):
# every person carries a ROLE (owner | team | client | public, default public) and,
# for a client, the domain they are a client of (a key in config/agent_domains.yml).
# The board resolves the audience from the verified sender's person, never from the
# message text. Alex's person (his Discord id) is seeded as the owner here and by
# AgentPerson.seed_owner!; everyone else starts public until an operator says otherwise
# (`bin/rails agent_people:role PERSON=<id> ROLE=team`).
class AddRoleToAgentPeople < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"

  class Person < ActiveRecord::Base
    self.table_name = "agent_people"
  end

  class Identity < ActiveRecord::Base
    self.table_name = "agent_person_identities"
  end

  def up
    add_column :agent_people, :role, :string, null: false, default: "public"
    add_column :agent_people, :client_domain, :string
    add_check_constraint :agent_people, "role IN ('owner', 'team', 'client', 'public')", name: "agent_people_role_known"

    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    Person.where(id: owner.agent_person_id).update_all(role: "owner") if owner
  end

  def down
    remove_check_constraint :agent_people, name: "agent_people_role_known"
    remove_column :agent_people, :client_domain
    remove_column :agent_people, :role
  end
end
