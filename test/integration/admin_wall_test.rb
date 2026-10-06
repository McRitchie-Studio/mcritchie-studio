require "test_helper"

# The hub's default-deny admin wall (app/controllers/concerns/admin_wall.rb), proven
# against the route table rather than a hand-kept list: every route served by an
# ApplicationController descendant is requested, so a route added tomorrow is walled
# here the moment it is drawn, unless AdminWall lists it.
#
# What counts as "refused" is read from the controller's own halt, not guessed from a
# status code: Rails instruments halted_callback.action_controller with the filter that
# halted, and the wall halts in exactly two filters.
class AdminWallTest < ActionDispatch::IntegrationTest
  WALL_FILTERS = %i[require_authentication require_admin_wall].freeze
  SAMPLE_VALUES = %w[x 1 2026 a].freeze

  # [controller_path, action, verb, path] for every route the wall governs.
  def self.walled_routes_table
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller && action

      klass = "#{controller.camelize}Controller".safe_constantize
      next unless klass && klass < ::ApplicationController

      path = sample_path(route)
      next unless path

      [controller, action, route.verb.presence || "GET", path]
    end.uniq { |controller, action, verb, _| [controller, action, verb] }
  end

  def self.sample_path(route)
    values = route.required_parts.to_h do |part|
      requirement = route.requirements[part]
      value = SAMPLE_VALUES.find { |candidate| requirement.nil? || requirement.match?(candidate) }
      [part, value]
    end
    return nil if values.values.any?(&:nil?)

    route.format(values)
  end

  def routes_table
    @routes_table ||= self.class.walled_routes_table
  end

  # Runs the request and returns the wall filter that halted it, or nil. With
  # past_the_wall: an error raised by the action itself is swallowed: the request
  # got through the wall, which is all the admin walk asks (it sends placeholder ids).
  def wall_halt_for(verb, path, past_the_wall: false, **options)
    halted = nil
    callback = lambda do |*, payload|
      filter = payload[:filter].to_s.to_sym
      halted = filter if WALL_FILTERS.include?(filter)
    end
    ActiveSupport::Notifications.subscribed(callback, "halted_callback.action_controller") do
      public_send(verb.split("|").first.downcase, path, **options)
    rescue StandardError
      raise unless past_the_wall
    end
    halted
  end

  def public_route?(controller, action) = AdminWall.public?(controller, action)
  def signed_in_route?(controller, action) = AdminWall.signed_in?(controller, action)

  test "[unit] the route walk finds the hub's controllers, with ops pages and public pages both present" do
    controllers = routes_table.map(&:first).uniq
    %w[tasks dashboard heartbeat docs releases landing packages].each do |controller|
      assert_includes controllers, controller, "the route walk should reach #{controller}"
    end
    assert routes_table.size > 200, "expected the whole route table, got #{routes_table.size} routes"
  end

  test "[unit] every listed public and signed-in action is a routed action" do
    routed = routes_table.map { |controller, action, *| [controller, action] }.to_set
    AdminWall::PUBLIC.merge(AdminWall::SIGNED_IN).each do |controller, actions|
      actions.each do |action|
        assert_includes routed, [controller, action],
                        "AdminWall lists #{controller}##{action}, which no route draws; drop it from the list"
      end
    end
  end

  test "[unit] the public and signed-in lists do not overlap" do
    overlap = AdminWall::PUBLIC.flat_map { |c, actions| actions.map { |a| [c, a] } } &
              AdminWall::SIGNED_IN.flat_map { |c, actions| actions.map { |a| [c, a] } }
    assert_empty overlap
  end

  test "[unit] the ops surfaces are walled and the marketing and legal pages are public" do
    walled = %w[dashboard#index tasks#index tasks#show tasks#deployments releases#index epics#index
                triage#index agents#index heartbeat#show heartbeat#insights intelligence#index
                pokemon#index builders#index usages#index docs#index docs#show launcher#index
                chat#index model_pipeline#index people#index appearances#show photo_scouting#show
                news#index contents#index teams#index sizings#show]
    walled.each do |pair|
      controller, action = pair.split("#")
      assert_not public_route?(controller, action), "#{pair} must be behind the wall"
      assert_not signed_in_route?(controller, action), "#{pair} must need an admin"
    end

    public_pages = %w[landing#index landing#terms landing#privacy landing#about packages#index packages#stack
                      build#new build#create build#show build#check contact_submissions#new
                      contact_submissions#create unsubscribes#show email_tracking#open links#index
                      schedule#index nfl#index rankings#quarterback games#season depth_charts#show
                      lineup_graphics#show team_grades#show contracts#index tasks#local_review]
    public_pages.each do |pair|
      assert public_route?(*pair.split("#")), "#{pair} must stay public"
    end
  end

  test "[integration] a visitor is sent to sign-in on every walled route" do
    walled = routes_table.reject { |controller, action, *| public_route?(controller, action) }
    assert walled.any?

    walled.each do |controller, action, verb, path|
      halted = wall_halt_for(verb, path)
      assert halted, "#{verb} #{path} (#{controller}##{action}) answered a visitor without the wall"
      assert_redirected_to login_path, "#{verb} #{path} should send a visitor to sign-in"
    end
  end

  test "[integration] a signed-in non-admin is refused on every walled route" do
    log_in_as(users(:viewer))
    walled = routes_table.reject do |controller, action, *|
      public_route?(controller, action) || signed_in_route?(controller, action)
    end

    walled.each do |controller, action, verb, path|
      halted = wall_halt_for(verb, path)
      assert_equal :require_admin_wall, halted,
                   "#{verb} #{path} (#{controller}##{action}) let a signed-in non-admin through"
      assert_redirected_to root_path
      assert_equal "Not authorized", flash[:alert]
    end
  end

  test "[integration] a non-admin's JSON request gets 403 and a visitor's gets 401, never a redirect" do
    get tasks_path, as: :json
    assert_response :unauthorized

    log_in_as(users(:viewer))
    get tasks_path, as: :json
    assert_response :forbidden
    post heartbeat_grade_path(id: 1), params: { score: 1 }, as: :json
    assert_response :forbidden
  end

  test "[integration] a signed-in non-admin still reaches their own account pages" do
    log_in_as(users(:viewer))
    routes_table.select { |controller, action, verb, _| signed_in_route?(controller, action) && verb == "GET" }
                .each do |controller, action, verb, path|
      assert_nil wall_halt_for(verb, path), "#{controller}##{action} should serve a signed-in user"
    end
  end

  test "[integration] an admin passes the wall on every walled page" do
    log_in_as(users(:alex))
    routes_table.select { |controller, action, verb, _| verb == "GET" && !public_route?(controller, action) }
                .each do |controller, action, verb, path|
      assert_nil wall_halt_for(verb, path, past_the_wall: true),
                 "#{verb} #{path} (#{controller}##{action}) refused an admin"
    end
  end

  test "[integration] every public page still answers a visitor" do
    routes_table.select { |controller, action, verb, _| verb == "GET" && public_route?(controller, action) }
                .each do |controller, action, verb, path|
      assert_nil wall_halt_for(verb, path), "#{verb} #{path} (#{controller}##{action}) refused a visitor"
    end
  end
end
