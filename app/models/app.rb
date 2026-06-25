# The canonical managed-app registry. Source of truth for an app's display name
# and STATUS-LINE IDENTITY (color + emoji). The Task model stamps an app's color
# onto a task's devops (see Task#sync_app_identity) so bin/statusline can tint the
# app slug without DB access (bin/task / bin/agent-worktree are API clients), the
# same way the Pokémon mascot's signature color rides the marker.
class App < ApplicationRecord
  include Sluggable

  # The default app a brand-new session adopts before any task exists — the
  # SessionStart hook seeds "<random Pokémon> · mcritchie-studio".
  DEFAULT_SLUG = "mcritchie-studio".freeze

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :active, -> { where(status: "active") }

  def self.default
    find_by(slug: DEFAULT_SLUG)
  end

  # Sluggable#set_slug assigns `slug = name_slug` on save; for an app the slug IS
  # the repo slug, which equals the parameterized name ("McRitchie Studio" →
  # "mcritchie-studio"), so this keeps slug and name in lockstep.
  def name_slug
    name.to_s.parameterize
  end
end
