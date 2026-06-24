# The Pokémon mascot for an agent SESSION, drawn + stored EAGERLY — at session
# start (a SessionStart hook → `bin/task session-mascot`), before any task exists
# — so bin/statusline shows the handle in seconds instead of only once the first
# task lands (~minutes in). One row per session_id; the board task adopts it
# (Task#session_mascot_slug) so the status bar and the board always agree.
class SessionMascot < ApplicationRecord
  validates :session_id,  presence: true, uniqueness: true
  validates :mascot_slug, presence: true

  # The stable mascot for a session — drawn once, then reused. Honors a mascot a
  # live task of this session already carries (an in-flight session keeps its
  # handle), else draws one unique among live tasks AND other sessions. Returns
  # the SessionMascot, or nil when no Pokémon can be drawn (none seeded). The
  # find-or-create converges concurrent first-calls onto a single row.
  def self.for(session_id)
    sid = session_id.to_s.strip
    return nil if sid.empty?

    if (existing = find_by(session_id: sid))
      return existing
    end

    slug = draw_for(sid)
    return nil unless slug

    create!(session_id: sid, mascot_slug: slug)
  rescue ActiveRecord::RecordNotUnique
    find_by(session_id: sid) # lost the create race; the winner's row is the truth
  end

  # The slug to assign a fresh session: reuse a live peer task's mascot for this
  # session, else draw one not already spoken for.
  def self.draw_for(sid)
    peer = Task.live.detect do |task|
      task.metadata&.dig("devops", "session_id").to_s == sid &&
        task.metadata&.dig("devops", "mascot").present?
    end
    return peer.metadata.dig("devops", "mascot") if peer

    Pokemon.draw(exclude: taken)&.slug
  end

  # Mascots already spoken for — live tasks' + every other session's — so two
  # sessions never share a Pokémon.
  def self.taken
    Task.active_mascots | pluck(:mascot_slug)
  end

  def pokemon
    @pokemon ||= Pokemon.find_by(slug: mascot_slug)
  end
end
