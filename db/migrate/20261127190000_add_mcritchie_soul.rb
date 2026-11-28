# frozen_string_literal: true

# Alex McRitchie bought a third Mad Lad, #4374, on 2026-11-27 and made it the face of
# a new soul, McRitchie: the voice of McRitchie Industries (mcritchie-soul-wears-4374).
#
# config/souls.yml is the roster, but a deploy runs db:migrate, not the seeds, so a
# deployed database never gets the row from the seed alone. This creates it with the
# record's own fields. A row that already exists (a desk seeded from this tree) is
# left exactly as it is.
#
# Down removes the row only while nothing hangs off it: the activities, setups,
# skill assignments and usages keys restrict a delete, and that history is worth
# more than a clean rollback.
class AddMcritchieSoul < ActiveRecord::Migration[8.1]
  SLUG = "mcritchie"
  CHILD_TABLES = %w[activities agent_setups skill_assignments usages].freeze

  # Schema-pinned shim so the data move never depends on the live model.
  class AgentRow < ActiveRecord::Base
    self.table_name = "agents"
  end

  def up
    AgentRow.reset_column_information
    if AgentRow.exists?(slug: SLUG)
      say "#{SLUG} agent row already present: left alone"
      return
    end

    AgentRow.create!(
      slug: SLUG,
      name: "McRitchie",
      status: "active",
      agent_type: "worker",
      title: "McRitchie Industries Agent",
      description: "The voice of McRitchie Industries, the holding company: lenders, the acquisition and owner-level correspondence. " \
                   "Not yet launched. Wears Mad Lads #4374; Alex wears #4485. Never the human: Alex McRitchie is always named in full.",
      avatar: "/agents/mcritchie-4374.webp",
      position: 10,
      metadata: { "emoji" => "🏛", "color" => "#0F766E", "review_role" => nil, "reviewer" => false }
    )
    say "#{SLUG} agent row created"
  end

  def down
    AgentRow.reset_column_information
    row = AgentRow.find_by(slug: SLUG)
    return say("#{SLUG} agent row absent: nothing to remove") unless row

    quoted = connection.quote(SLUG)
    busy = CHILD_TABLES.select { |table| connection.select_value("SELECT 1 FROM #{table} WHERE agent_slug = #{quoted} LIMIT 1") }
    if busy.any?
      say "#{SLUG} agent row kept: #{busy.join(', ')} reference it"
    else
      row.delete
      say "#{SLUG} agent row removed"
    end
  end
end
