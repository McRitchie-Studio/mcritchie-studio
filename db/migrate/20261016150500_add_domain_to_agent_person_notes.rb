# A person's notes are scoped per app DOMAIN (docs/agents/system/agent-message-loop.md,
# "Whose memory"): each note records the domain of the soul that filed it
# (config/agent_domains.yml `souls:`), so a client's or a member of the public's
# notes filed while Turf answered are shown only to Turf's souls. "" is the
# domain of a soul the registry maps to none.
#
# The fingerprint is now unique per (person, domain): the same fact said to two
# domains is two notes, each visible in its own domain.
#
# BACKFILL. Every existing note takes its filing soul's domain from the souls map
# as it stands when this runs; a soul the map does not name stays "".
class AddDomainToAgentPersonNotes < ActiveRecord::Migration[8.1]
  DOMAINS_PATH = "config/agent_domains.yml"

  class Note < ActiveRecord::Base
    self.table_name = "agent_person_notes"
  end

  def up
    add_column :agent_person_notes, :domain, :string, null: false, default: ""

    souls_map.each do |soul, domain|
      Note.where(soul_slug: soul.to_s).update_all(domain: domain.to_s)
    end

    remove_index :agent_person_notes, %i[agent_person_id fingerprint]
    add_index :agent_person_notes, %i[agent_person_id domain fingerprint], unique: true,
                                                                          name: "index_agent_person_notes_on_person_domain_fingerprint"
  end

  def down
    remove_index :agent_person_notes, name: "index_agent_person_notes_on_person_domain_fingerprint"
    # The older index allows one fingerprint per person: keep the oldest.
    execute <<~SQL.squish
      DELETE FROM agent_person_notes a USING agent_person_notes b
      WHERE a.agent_person_id = b.agent_person_id AND a.fingerprint = b.fingerprint AND a.id > b.id
    SQL
    add_index :agent_person_notes, %i[agent_person_id fingerprint], unique: true
    remove_column :agent_person_notes, :domain
  end

  private

  def souls_map
    path = Rails.root.join(DOMAINS_PATH)
    config = File.file?(path) ? YAML.safe_load_file(path, aliases: false) : {}
    souls = config.is_a?(Hash) ? config["souls"] : nil
    souls.is_a?(Hash) ? souls : {}
  end
end
