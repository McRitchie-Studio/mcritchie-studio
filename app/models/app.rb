# The managed-app registry rows, seeded from config/apps.yml (AppCatalog) by
# db/seeds/00_apps.rb: an app's display name and STATUS-LINE IDENTITY (color +
# emoji) as the database holds them. The Task model stamps an app's color
# onto a task's devops (see Task#sync_app_identity) so bin/statusline can tint the
# app slug without DB access (bin/task / bin/agent-worktree are API clients), the
# same way the Pokémon mascot's signature color rides the marker.
class App < ApplicationRecord
  include Sluggable

  # A desk record names its app by slug (no association here).
  has_slug_children "desk_records" => :app_slug

  # Who owns the app (AppMembership, docs/agents/system/app-owners.md).
  has_many :memberships, class_name: "AppMembership", foreign_key: :app_slug, primary_key: :slug,
                         inverse_of: :app, dependent: :delete_all

  # A client app's CTO, as data (AppCto, docs/agents/system/client-cto.md). Our
  # own apps' CTOs are souls in config/cto_reports.yml and have none.
  has_one :client_cto, class_name: "AppCto", foreign_key: :app_slug, primary_key: :slug,
                       inverse_of: :app, dependent: :delete

  # The static bundles this app has published to the shared client-app host
  # (docs/agents/system/client-app-host.md). `preview_version` names the live one;
  # ClientApps::Publish is the only writer of either.
  has_many :preview_versions, class_name: "AppPreviewVersion", foreign_key: :app_slug, primary_key: :slug,
                              inverse_of: :app, dependent: :delete_all

  # The default app a brand-new session adopts before any task exists — the
  # SessionStart hook seeds "<random Pokémon> · mcritchie-studio".
  DEFAULT_SLUG = "mcritchie-studio".freeze

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  # No `active` scope: status here is config/apps.yml's word, where a live app
  # may be showcase or delinquent, so `where(status: "active")` would drop Turf
  # Monster. Ask AppCatalog (`Entry#live?`) whether an app is live.

  # The live bundle's history row, or nil when nothing is published yet.
  def current_preview
    return nil if preview_version.blank?

    preview_versions.find_by(version: preview_version)
  end

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
