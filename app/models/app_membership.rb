# One user's standing on one app (docs/agents/system/app-owners.md). Today the
# only role is `owner`: the person whose app it is, who signs in to the hub to
# set their app's CTO settings (/applications, /agents/:slug/settings).
#
# A membership is not a hub role. An owner stays a `viewer` in users.role and
# reaches nothing but their own app's pages; admins reach every app without one.
class AppMembership < ApplicationRecord
  ROLES = %w[owner].freeze

  # The known owners, app slug => email (Alex McRitchie, 2026-10-16). The table's own
  # migration seeds the same three; this is the re-seed and post-deploy step.
  OWNERS = {
    "mcritchie-studio" => "alex@mcritchie.studio",
    "turf-monster" => "alex@turfmonster.media",
    "cyvasse" => "amcritchie@gmail.com"
  }.freeze

  belongs_to :app, foreign_key: :app_slug, primary_key: :slug, inverse_of: :memberships
  belongs_to :user, foreign_key: :user_slug, primary_key: :slug, inverse_of: :app_memberships

  validates :role, inclusion: { in: ROLES }
  validates :app_slug, uniqueness: { scope: :user_slug }

  scope :owners, -> { where(role: "owner") }

  # Idempotent: creates each OWNERS row whose app and user exist, and says what
  # it did per app ("created", "present", "no app", "no user"). Safe on every run.
  # The migration's SQL step skips a user with no slug; this one gives it one.
  def self.seed_owners!(owners = OWNERS)
    owners.to_h do |app_slug, email|
      app = App.find_by(slug: app_slug)
      user = User.where("LOWER(email) = ?", email.downcase).first
      # A row with no slug yet gets one on its next save (Sluggable).
      user.save! if user && user.slug.blank?
      outcome =
        if app.nil? then "no app"
        elsif user.nil? then "no user"
        else
          membership = find_or_create_by!(app_slug: app.slug, user_slug: user.slug) { |m| m.role = "owner" }
          membership.previously_new_record? ? "created" : "present"
        end
      [ app_slug, outcome ]
    end
  end
end
