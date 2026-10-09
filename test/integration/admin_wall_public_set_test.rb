require "test_helper"

# The admin wall is a security boundary, and its public list is now assembled from
# two sources: the pages config/navigation.yml declares public (AdminWall::PUBLIC_PAGES)
# and the explicit non-page actions (AdminWall::PUBLIC_ACTIONS). This file pins the
# RESULT as one explicit list, so an edit to either source that opens or closes
# anything fails here and shows a reviewer the exact action that moved.
#
# Opening a page on purpose: change its audience in config/navigation.yml (or add
# the action to PUBLIC_ACTIONS) AND add it to EXPECTED_PUBLIC below.
class AdminWallPublicSetTest < ActionDispatch::IntegrationTest
  # Every controller#action a visitor may reach. Nothing else is public.
  EXPECTED_PUBLIC = %w[
    build#check build#create build#new build#show
    contact_submissions#create contact_submissions#new
    contracts#index
    depth_charts#show
    dev/board#advance_release dev/board#delete dev/board#generate dev/board#move
    dev/board#open_release dev/board#rebroadcast_release_modules dev/board#reset_release
    dev/board#ship_release
    email_tracking#click email_tracking#goal email_tracking#open
    games#season games#show games#week
    landing#about landing#index landing#privacy landing#terms
    lineup_graphics#show
    links#index
    magic_links#create
    nfl#index nfl#rosters
    omniauth_callbacks#create omniauth_callbacks#failure
    packages#index packages#stack
    rankings#coaches rankings#coverage rankings#defense rankings#offensive_line
    rankings#pass_first rankings#pass_rush rankings#player_impact rankings#prospects
    rankings#quarterback rankings#receiving rankings#rushing rankings#team_unit
    registrations#create registrations#new
    schedule#index
    sessions#destroy sessions#new sessions#sso_continue sessions#sso_login
    studio/links#consume studio/links#show
    studio/local_emails#index
    studio/local_reviews#show
    tasks#local_review
    team_grades#show
    unsubscribes#create unsubscribes#resubscribe unsubscribes#show
  ].freeze

  def pairs(actions_by_controller)
    actions_by_controller.flat_map { |controller, actions| actions.map { |action| "#{controller}##{action}" } }
  end

  # The public set the wall would hold for a registry and an explicit list.
  def public_set(public_pages, public_actions)
    (pairs(public_pages) + pairs(public_actions)).sort
  end

  # [controller_path, action] for every routed action the wall governs.
  def governed_actions
    @governed_actions ||= Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller && action

      klass = "#{controller.camelize}Controller".safe_constantize
      [ controller, action ] if klass && klass < ::ApplicationController
    end.uniq
  end

  test "[unit] the wall's public set is exactly the pinned list" do
    actual = pairs(AdminWall::PUBLIC).sort

    assert_equal [], actual - EXPECTED_PUBLIC, "these actions became PUBLIC; if intended, add them to EXPECTED_PUBLIC"
    assert_equal [], EXPECTED_PUBLIC - actual, "these actions stopped being public; if intended, drop them from EXPECTED_PUBLIC"
    assert_equal EXPECTED_PUBLIC.sort, actual
    assert_equal EXPECTED_PUBLIC.uniq, EXPECTED_PUBLIC
  end

  test "[unit] the public set has two sources and they never name the same action" do
    assert_equal public_set(Navigation.public_actions, AdminWall::PUBLIC_ACTIONS), pairs(AdminWall::PUBLIC).sort
    assert_empty pairs(AdminWall::PUBLIC_PAGES) & pairs(AdminWall::PUBLIC_ACTIONS)
    assert_equal pairs(Navigation.public_actions).sort, pairs(AdminWall::PUBLIC_PAGES).sort
  end

  test "[unit] control: a registry edit that opens an admin page no longer matches the pinned list" do
    data = YAML.safe_load_file(Navigation::PATH)
    data["pages"]["tasks"]["audience"] = "public"
    opened = public_set(Navigation.new(data).public_actions, AdminWall::PUBLIC_ACTIONS)

    assert_equal [ "tasks#index" ], opened - EXPECTED_PUBLIC
    assert_not_equal EXPECTED_PUBLIC.sort, opened
  end

  test "[unit] control: a registry edit that walls a public page no longer matches the pinned list" do
    data = YAML.safe_load_file(Navigation::PATH)
    data["pages"]["packages"]["audience"] = "admin"
    closed = public_set(Navigation.new(data).public_actions, AdminWall::PUBLIC_ACTIONS)

    assert_equal [ "packages#index" ], EXPECTED_PUBLIC - closed
  end

  test "[unit] control: an action added to the explicit list no longer matches the pinned list" do
    widened = public_set(Navigation.public_actions, AdminWall::PUBLIC_ACTIONS.merge("heartbeat" => %w[grade]))

    assert_equal [ "heartbeat#grade" ], widened - EXPECTED_PUBLIC
  end

  # Fail-closed: the wall opens an action only when one of the two sources names
  # it. Every other routed action, listed in the registry or not, needs a session.
  test "[unit] every routed action is a registry public page, an explicit public action, signed-in, or walled" do
    registry_public = pairs(Navigation.public_actions)
    explicit = pairs(AdminWall::PUBLIC_ACTIONS)
    assert governed_actions.size > 200, "expected the whole route table, got #{governed_actions.size} actions"

    walled = governed_actions.reject do |controller, action|
      pair = "#{controller}##{action}"
      sources = [ registry_public.include?(pair), explicit.include?(pair), AdminWall.signed_in?(controller, action) ]
      assert_operator sources.count(true), :<=, 1, "#{pair} is opened by more than one list"
      assert_equal sources[0] || sources[1], AdminWall.public?(controller, action),
                   "#{pair}: the wall and its two sources disagree"
      sources.any?
    end

    assert walled.size > 150, "expected most of the route table behind the wall, got #{walled.size}"
    walled.each do |controller, action|
      assert_not AdminWall.public?(controller, action), "#{controller}##{action} is listed nowhere and must be walled"
    end
    assert_not AdminWall.public?("a_controller_drawn_tomorrow", "index")
  end

  test "[unit] every public action in either source is a routed action the wall governs" do
    routed = governed_actions.map { |controller, action| "#{controller}##{action}" }

    assert_empty EXPECTED_PUBLIC - routed, "listed public, yet no wall-governed route serves it"
  end

  test "[unit] every registry page marked admin is behind the wall" do
    admin_pages = Navigation.pages.values.reject(&:public?)
    assert admin_pages.size > 40

    admin_pages.each do |page|
      assert_not AdminWall.public?(page.controller, page.action), "#{page.key} (#{page.action_id}) is an admin page"
      assert_not AdminWall.signed_in?(page.controller, page.action), "#{page.key} (#{page.action_id}) must need an admin"
    end
  end

  test "[integration] a visitor is sent to sign-in by every admin page a nav links, and reaches every public one" do
    view = Rails.application.routes.url_helpers
    Navigation.placed_keys.map { |key| Navigation.page(key) }.each do |page|
      get page.path(view)
      if page.public?
        assert_not_equal login_url, response.location, "#{page.key} is a public nav entry; the wall must let a visitor in"
      else
        assert_redirected_to login_path, "#{page.key} is an admin nav entry and must send a visitor to sign-in"
      end
    end
  end
end
