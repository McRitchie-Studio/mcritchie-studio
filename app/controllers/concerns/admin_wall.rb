# The hub's default-deny wall. Every action served by a controller that inherits
# ApplicationController needs an ADMIN unless PUBLIC names it (any visitor) or
# SIGNED_IN names it (any signed-in user). An admin wall rather than a login wall
# because hub signup is open: a plain login keeps nobody out.
#
# A route added tomorrow is walled until someone lists it here.
# test/integration/admin_wall_test.rb walks the route table and requests every
# walled route as a visitor and as a signed-in non-admin, so a new public page is
# a deliberate edit of this file, never an accident.
#
# Outside the wall by construction, because they do not inherit ApplicationController:
# the bearer-gated /api/v1 namespace (Api::V1::BaseController), the HMAC-signed
# /webhooks/*, /up, Active Storage, Action Mailbox and the PWA files.
module AdminWall
  extend ActiveSupport::Concern

  # controller_path => actions any visitor may reach.
  PUBLIC = {
    # Marketing, legal and the customer funnel.
    "landing" => %w[index terms privacy about],
    "packages" => %w[index stack],
    "build" => %w[new create show check],
    "contact_submissions" => %w[new create],
    "links" => %w[index],
    "schedule" => %w[index],
    # Email: the unsubscribe page and the open/click/goal tracking pixels.
    "unsubscribes" => %w[show create resubscribe],
    "email_tracking" => %w[open click goal],
    # The NFL pages.
    "nfl" => %w[index rosters],
    "rankings" => %w[quarterback offensive_line receiving rushing defense pass_rush coverage
                     prospects coaches pass_first team_unit player_impact],
    "games" => %w[season week show],
    "depth_charts" => %w[show],
    "lineup_graphics" => %w[show],
    "team_grades" => %w[show],
    "contracts" => %w[index],
    # The board's WAITING APPROVAL button: it must work logged out, because it
    # hands off to the desk's own sign-in (TasksController#local_review).
    "tasks" => %w[local_review],
    # Signing in, signing up and the magic-link doors.
    "sessions" => %w[new create sso_continue sso_login destroy],
    "registrations" => %w[new create],
    "omniauth_callbacks" => %w[create failure],
    "magic_links" => %w[create],
    "studio/links" => %w[show consume],
    # Local-development only (the engine refuses them elsewhere): the review
    # hop's mint and the captured-email inbox.
    "studio/local_reviews" => %w[show],
    "studio/local_emails" => %w[index],
    # Local-development only (Dev::BoardController#ensure_local!): the board fixture tool.
    "dev/board" => %w[generate move delete ship_release open_release advance_release
                      reset_release rebroadcast_release_modules]
  }.transform_values(&:freeze).freeze

  # controller_path => actions any signed-in user may reach: their own account and
  # their own /build request.
  SIGNED_IN = {
    # The /build funnel's name step: a customer claims a subdomain for their draft.
    "build" => %w[update],
    "studio/profiles" => %w[show edit update avatar unlink_google subscribe_newsletter unsubscribe_newsletter],
    "studio/onboarding" => %w[first_name skip_first_name]
  }.transform_values(&:freeze).freeze

  def self.public?(controller_path, action)
    PUBLIC.fetch(controller_path.to_s, []).include?(action.to_s)
  end

  def self.signed_in?(controller_path, action)
    SIGNED_IN.fetch(controller_path.to_s, []).include?(action.to_s)
  end

  included do
    # The engine's require_authentication runs on every action; a public action
    # skips it here, so no controller spells its own skip.
    skip_before_action :require_authentication, if: :admin_wall_public?
    before_action :require_admin_wall, unless: :admin_wall_public?
  end

  private

  def admin_wall_public?
    AdminWall.public?(controller_path, action_name)
  end

  # Format-aware, because the board, drawers and inline cells post JSON and Turbo:
  # a visitor gets the engine's login answer (a redirect on HTML, 401 otherwise),
  # a signed-in non-admin gets 403 (a redirect on HTML). The engine's require_admin
  # redirects every format, and a JSON fetch that follows a redirect to an HTML
  # page surfaces as a 500 on the original request.
  def require_admin_wall
    return require_authentication unless logged_in?
    return if admin?
    return if AdminWall.signed_in?(controller_path, action_name)

    respond_to do |format|
      format.html { redirect_to root_path, alert: "Not authorized" }
      format.any  { head :forbidden }
    end
  end
end
