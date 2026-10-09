# The hub's default-deny wall. Every action served by a controller that inherits
# ApplicationController needs an ADMIN unless PUBLIC names it (any visitor) or
# SIGNED_IN names it (any signed-in user). An admin wall rather than a login wall
# because hub signup is open: a plain login keeps nobody out.
#
# PUBLIC has two sources, and no third:
#
#   PUBLIC_PAGES    the pages config/navigation.yml declares `audience: public`.
#                   The navs and the wall read the same entries, so a link shown
#                   to a visitor and the page behind it cannot disagree.
#   PUBLIC_ACTIONS  the explicit list below: public actions that are not site
#                   pages (form posts, probes, tracking pixels, redirects) and
#                   the auth, unsubscribe and local-development doors, whose
#                   screens belong to a flow rather than to the site's navigation.
#
# A route added tomorrow is walled until someone lists it in one of the two.
# test/integration/admin_wall_public_set_test.rb pins the whole public set as an
# explicit list, and test/integration/admin_wall_test.rb walks the route table and
# requests every walled route as a visitor and as a signed-in non-admin, so a new
# public page is a deliberate edit a reviewer sees, never an accident.
#
# Outside the wall by construction, because they do not inherit ApplicationController:
# the bearer-gated /api/v1 namespace (Api::V1::BaseController), the HMAC-signed
# /webhooks/*, /up, Active Storage, Action Mailbox and the PWA files.
module AdminWall
  extend ActiveSupport::Concern

  # controller_path => page actions any visitor may open, from the registry.
  PUBLIC_PAGES = Navigation.public_actions.transform_values(&:freeze).freeze

  # controller_path => actions any visitor may reach that are not site pages.
  PUBLIC_ACTIONS = {
    # The customer funnel's writes and its live subdomain probe.
    "build" => %w[create check],
    "contact_submissions" => %w[create],
    # Email: the unsubscribe page and the open/click/goal tracking pixels.
    "unsubscribes" => %w[show create resubscribe],
    "email_tracking" => %w[open click goal],
    # The board's WAITING APPROVAL button: it must work logged out, because it
    # hands off to the desk's own sign-in (TasksController#local_review).
    "tasks" => %w[local_review],
    # Signing in, signing up and the magic-link doors.
    "sessions" => %w[new sso_continue sso_login destroy],
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

  # controller_path => actions any visitor may reach: the pages plus the actions.
  PUBLIC = PUBLIC_PAGES.merge(PUBLIC_ACTIONS) { |_, pages, actions| (pages + actions).freeze }.freeze

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
