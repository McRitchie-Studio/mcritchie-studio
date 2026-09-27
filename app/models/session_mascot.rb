# The Pokémon mascot for an agent SESSION, drawn + stored EAGERLY — at session
# start (a SessionStart hook → `bin/task session-mascot`), before any task exists
# — so bin/statusline shows the handle in seconds instead of only once the first
# task lands (~minutes in). One row per session_id; the board task adopts it
# (Task#session_mascot_draw) so the status bar and the board always agree.
class SessionMascot < ApplicationRecord
  validates :session_id,  presence: true, uniqueness: true
  validates :mascot_slug, presence: true
  validates :gender, inclusion: { in: Pokemon::GENDERS }, allow_nil: true

  # The stable mascot for a session — drawn once, then reused. Honors a mascot a
  # live task of this session already carries (an in-flight session keeps its
  # handle), else draws one unique among live tasks AND other sessions. Subagent
  # sessions can pass a parent session; they draw from the parent's evolution tree
  # while avoiding sibling duplicates until that tree is exhausted. Returns the
  # SessionMascot, or nil when no Pokémon can be drawn (none seeded). The
  # find-or-create converges concurrent first-calls onto a single row.
  def self.for(session_id, parent_session_id: nil)
    sid = session_id.to_s.strip
    return nil if sid.empty?

    if (existing = find_by(session_id: sid))
      return existing
    end

    parent_sid = parent_session_id.to_s.strip.presence
    if parent_sid && (parent = find_by(session_id: parent_sid))
      parent.with_lock do
        create_with_draw!(sid, parent_session_id: parent_sid, parent_mascot_slug: parent.mascot_slug,
                               parent_gender: parent.gender)
      end
    else
      create_with_draw!(sid, parent_session_id: parent_sid)
    end
  rescue ActiveRecord::RecordNotUnique
    find_by(session_id: sid) # lost the create race; the winner's row is the truth
  end

  # The slug to assign a fresh session: reuse a live peer task's mascot for this
  # session; for a known parent session, draw from that parent's evolution tree;
  # else draw one not already spoken for.
  #
  # A subagent session's draw is pruned to the branches the parent's GENDER allows
  # (a female Nidoran parent never hands a child the Nidorino line).
  def self.draw_for(sid, parent_session_id: nil, parent_mascot_slug: nil, parent_gender: nil)
    draw_with_gender_hint(sid, parent_session_id: parent_session_id, parent_mascot_slug: parent_mascot_slug,
                               parent_gender: parent_gender).first
  end

  # [slug, gender hint] — the hint is the gender the slug's source already carries
  # (a live peer task's devops.mascot_gender, or the parent session's gender), nil
  # for a fresh deck draw. create_with_draw! keeps a hint the species allows and
  # rolls otherwise.
  def self.draw_with_gender_hint(sid, parent_session_id: nil, parent_mascot_slug: nil, parent_gender: nil)
    peer = Task.live.detect do |task|
      task.metadata&.dig("devops", "session_id").to_s == sid &&
        task.metadata&.dig("devops", "mascot").present?
    end
    return [peer.metadata.dig("devops", "mascot"), peer.metadata.dig("devops", "mascot_gender")] if peer

    if parent_session_id.present?
      parent = find_by(session_id: parent_session_id) if parent_mascot_slug.blank? || parent_gender.blank?
      parent_slug = parent_mascot_slug.presence || parent&.mascot_slug
      parent_gender = parent_gender.presence || parent&.gender
      if (slug = draw_for_parent_tree(parent_session_id, parent_slug, gender: parent_gender))
        return [slug, parent_gender]
      end
    end

    [Pokemon.draw(exclude: taken)&.slug, nil]
  end

  def self.create_with_draw!(sid, parent_session_id: nil, parent_mascot_slug: nil, parent_gender: nil)
    slug, gender_hint = draw_with_gender_hint(sid, parent_session_id: parent_session_id,
                                                   parent_mascot_slug: parent_mascot_slug,
                                                   parent_gender: parent_gender)
    return nil unless slug

    # The shiny roll happens HERE, once per session draw (1-in-25 prod, 1-in-2
    # dev/QA) — the session's tasks then adopt the flag as devops.mascot_shiny.
    # So does the GENDER roll, weighted by the species' gender_rate; the tasks
    # adopt it as devops.mascot_gender.
    create!(session_id: sid, parent_session_id: parent_session_id.presence,
            mascot_slug: slug, shiny: Pokemon.roll_shiny?, gender: gender_for(slug, gender_hint))
  end

  # The session's gender: an inherited hint the species allows (a subagent keeps
  # its parent's), else a fresh roll by gender_rate. nil for a genderless species
  # or a slug with no seeded row.
  def self.gender_for(slug, hint = nil)
    pokemon = Pokemon.find_by(slug: slug)
    return nil unless pokemon

    hint = Pokemon.normalize_gender(hint)
    hint && pokemon.allows_gender?(hint) ? hint : pokemon.roll_gender
  end

  def self.draw_for_parent_tree(parent_sid, parent_slug, gender: nil)
    return nil if parent_sid.blank? || parent_slug.blank?

    tree = Pokemon.evolution_tree_for(parent_slug, gender: gender)
    return nil if tree.empty?
    return parent_slug if tree.one?

    siblings = where(parent_session_id: parent_sid).pluck(:mascot_slug)
    available = tree - [parent_slug] - siblings - taken
    available = tree - [parent_slug] - siblings if available.empty?
    pool = available.presence || tree

    Pokemon.draw_from_slugs(pool)&.slug
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
