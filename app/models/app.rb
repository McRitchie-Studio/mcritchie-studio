# The managed-app registry rows, seeded from config/apps.yml (AppCatalog) by
# db/seeds/00_apps.rb: an app's display name and STATUS-LINE IDENTITY (color +
# emoji) as the database holds them. The Task model stamps an app's color
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

  # No `active` scope: status here is config/apps.yml's word, where a live app
  # may be showcase or delinquent, so `where(status: "active")` would drop Turf
  # Monster. Ask AppCatalog (`Entry#live?`) whether an app is live.

  def self.default
    find_by(slug: DEFAULT_SLUG)
  end

  # Sluggable#set_slug assigns `slug = name_slug` on save. An app's slug is its
  # repo slug from config/apps.yml, which a name does not always spell
  # ("10&5 Hospitality" is `10and5`), so the set slug stands.
  def name_slug
    slug.presence || name.to_s.parameterize
  end
end
