# The CTO web chat (docs/agents/system/agent-message-loop.md, "Web chat"): a web
# message's person is the hub user's `web` identity. Alex owns each app through a
# different hub account (docs/agents/system/app-owners.md): alex@mcritchie.studio,
# alex@turfmonster.media and amcritchie@gmail.com. Each of those users that exists
# gets a `web` identity on the owner's person (found by his Discord id, as
# AddEnvelopeToAgentMessages found it), so his chat with any app's CTO is answered
# as the owner. Idempotent, and it never moves an identity that already belongs to
# someone. AgentPerson.seed_owner! does the same. No other user is linked: app
# ownership itself grants no agent authority.
class LinkOwnerWebIdentities < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"
  OWNER_HUB_EMAILS = %w[alex@mcritchie.studio alex@turfmonster.media amcritchie@gmail.com].freeze

  class Identity < ActiveRecord::Base
    self.table_name = "agent_person_identities"
  end

  class HubUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    return unless owner

    now = Time.current
    HubUser.where("LOWER(email) IN (?)", OWNER_HUB_EMAILS).order(:id).pluck(:id).each do |user_id|
      next if Identity.exists?(platform: "web", external_id: user_id.to_s)

      Identity.create!(agent_person_id: owner.agent_person_id, platform: "web", external_id: user_id.to_s,
                       display_name: "Alex", created_at: now, updated_at: now)
    end
  end

  def down
    owner = Identity.find_by(platform: "discord", external_id: OWNER_DISCORD_ID)
    return unless owner

    ids = HubUser.where("LOWER(email) IN (?)", OWNER_HUB_EMAILS).pluck(:id).map(&:to_s)
    Identity.where(platform: "web", external_id: ids, agent_person_id: owner.agent_person_id).delete_all
  end
end
