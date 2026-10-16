# The owner-only guard (docs/agents/system/agent-message-loop.md, "Held"): an
# addressed message from a sender config/agent_answerers.yml does not allow is
# stored `held`, never claimed, until an admin releases it. This adds the status
# to the CHECK, the two columns a release stamps, and holds every `received` row
# already waiting from a sender who is not allowed. Completed, dead, claimed and
# unrouted rows are left alone.
#
# The allow-list is read from the yml AS IT STANDS when this runs, with plain SQL
# rather than app code, so the migration does not move when the app does. Since
# agent-communication-sop the yml lists ROLES (`answered_roles`), and the roles
# column arrives in a LATER migration, so the owner (Alex's Discord identity, the
# person AddRoleToAgentPeople makes the owner) is always allowed here: a fresh
# migrate and a deploy that ships both migrations hold exactly what the new
# guard would.
class AddHeldToAgentMessages < ActiveRecord::Migration[8.1]
  STATUSES = %w[received claimed completed dead unrouted held].freeze
  PRIOR = %w[received claimed completed dead unrouted].freeze
  ANSWERERS = Rails.root.join("config/agent_answerers.yml")
  OWNER_DISCORD_ID = "536552944271753216"

  def up
    add_column :agent_messages, :hold_released_at, :datetime
    add_column :agent_messages, :hold_released_by, :string
    replace_status_check(STATUSES)
    hold_unallowed_received!
  end

  def down
    held = select_value("SELECT COUNT(*) FROM agent_messages WHERE status = 'held'").to_i
    if held.positive?
      raise ActiveRecord::IrreversibleMigration,
            "#{held} held message(s) would have no status to return to; release or delete them first"
    end

    replace_status_check(PRIOR)
    remove_column :agent_messages, :hold_released_by
    remove_column :agent_messages, :hold_released_at
  end

  private

  def replace_status_check(statuses)
    remove_check_constraint :agent_messages, name: "agent_messages_status_known"
    add_check_constraint :agent_messages, "status IN (#{statuses.map { |s| quote(s) }.join(', ')})",
                         name: "agent_messages_status_known"
  end

  def hold_unallowed_received!
    allowed = allowed_person_ids
    list = allowed.any? ? allowed.join(", ") : "NULL"
    ids = select_values(<<~SQL.squish).map(&:to_i)
      UPDATE agent_messages SET status = 'held', updated_at = NOW()
      WHERE status = 'received' AND (person_id IS NULL OR person_id NOT IN (#{list}))
      RETURNING id
    SQL
    ids.each do |id|
      execute(<<~SQL.squish)
        INSERT INTO agent_message_events (agent_message_id, kind, actor, detail, created_at)
        VALUES (#{id}, 'held', 'migration',
                #{quote({ "reason" => "sender is not on config/agent_answerers.yml" }.to_json)}::jsonb, NOW())
      SQL
    end
    say "held #{ids.size} received message(s) from senders not on config/agent_answerers.yml"
  end

  def allowed_person_ids
    entries = Array((File.exist?(ANSWERERS) && YAML.safe_load_file(ANSWERERS, aliases: false) || {})["answerers"])
    ids = entries.filter_map { |e| e.is_a?(Hash) ? e["person_id"].to_s[/\A\d+\z/]&.to_i : nil }
    ids += select_values(<<~SQL.squish).map(&:to_i)
      SELECT agent_person_id FROM agent_person_identities
      WHERE platform = 'discord' AND external_id = #{quote(OWNER_DISCORD_ID)}
    SQL
    entries.each do |e|
      identity = e.is_a?(Hash) ? e["identity"] : nil
      next unless identity.is_a?(Hash) && identity["platform"].present? && identity["external_id"].present?

      ids += select_values(<<~SQL.squish).map(&:to_i)
        SELECT agent_person_id FROM agent_person_identities
        WHERE platform = #{quote(identity['platform'].to_s)} AND external_id = #{quote(identity['external_id'].to_s)}
      SQL
    end
    ids.uniq
  end
end
