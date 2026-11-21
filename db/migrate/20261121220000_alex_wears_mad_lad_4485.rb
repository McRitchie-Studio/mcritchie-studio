# frozen_string_literal: true

# Alex McRitchie bought Mad Lads #4485 on 2026-11-21 and made it the Alex agent's
# face across the platform (alex-wears-mad-lad-4485). The portrait ships under a
# NEW filename, public/agents/alex-4485.webp, not over alex.webp: production serves
# public/ with a 7-day cache-control, so a same-name swap would show the old face
# to every returning visitor (and Cloudflare) for a week.
#
# agents.avatar is DATA (seeds are not re-run on deploy), so this moves the row.
# Only the exact old path moves: an avatar someone set by hand stays as it is.
class AlexWearsMadLad4485 < ActiveRecord::Migration[8.1]
  OLD = "/agents/alex.webp"
  NEW = "/agents/alex-4485.webp"

  # Schema-pinned shim so the data move never depends on the live model.
  class AgentRow < ActiveRecord::Base
    self.table_name = "agents"
  end

  def up = move(OLD, NEW)

  def down = move(NEW, OLD)

  private

  def move(from, to)
    AgentRow.reset_column_information
    count = AgentRow.where(slug: "alex", avatar: from).update_all(avatar: to, updated_at: Time.current)
    say "alex avatar #{from} -> #{to}: #{count} row(s)"
  end
end
