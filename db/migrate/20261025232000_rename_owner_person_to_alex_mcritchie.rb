# frozen_string_literal: true

# The owner's agent person reads "Alex McRitchie", never a bare "Alex", which
# names the client-facing agent since ritch-renamed-alex (2026-10-25). The prompt
# an agent answers from labels a sender by this name, so a bare "Alex" there
# would read as the agent. AgentPerson::OWNER carries the new name for a fresh
# seed; the release phase runs only db:migrate, so the deployed rows move here.
# Only the stock value moves, and only on the owner's own person (role owner, his
# Discord id) and its identities; a name set by hand is kept.
class RenameOwnerPersonToAlexMcritchie < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"

  def up = rename("Alex", "Alex McRitchie")
  def down = rename("Alex McRitchie", "Alex")

  private

  def rename(from, to)
    return unless table_exists?(:agent_people) && table_exists?(:agent_person_identities)

    owner_ids = "SELECT agent_person_id FROM agent_person_identities " \
                "WHERE platform = 'discord' AND external_id = #{quote(OWNER_DISCORD_ID)}"
    execute("UPDATE agent_people SET display_name = #{quote(to)}, updated_at = NOW() " \
            "WHERE role = 'owner' AND display_name = #{quote(from)} AND id IN (#{owner_ids})")
    execute("UPDATE agent_person_identities SET display_name = #{quote(to)}, updated_at = NOW() " \
            "WHERE display_name = #{quote(from)} AND agent_person_id IN " \
            "(SELECT id FROM agent_people WHERE role = 'owner' AND id IN (#{owner_ids}))")
  end

  def quote(value) = connection.quote(value)
end
