require "test_helper"

# [unit] the heartbeat surface sits behind the admin wall, pinned to the route
# table. A banked grade is printed into every new agent session's context, so no
# heartbeat action, read or write, may join AdminWall's public or signed-in lists.
# test/integration/admin_wall_test.rb proves the wall answers on each route.
class HeartbeatControllerTest < ActiveSupport::TestCase
  def heartbeat_routes
    Rails.application.routes.routes.select { |r| r.defaults[:controller] == "heartbeat" }
                                   .map { |r| [r.defaults[:action].to_sym, r.verb] }
  end

  test "[unit] every heartbeat route needs an admin" do
    assert heartbeat_routes.any?, "the route table names the heartbeat controller"

    heartbeat_routes.each do |action, verb|
      assert_not AdminWall.public?("heartbeat", action), "#{verb} heartbeat##{action} must not be public"
      assert_not AdminWall.signed_in?("heartbeat", action), "#{verb} heartbeat##{action} must need an admin"
    end
  end

  test "[unit] the write actions are the grade, activity grade and confirm endpoints" do
    writes = heartbeat_routes.reject { |_, verb| verb == "GET" }.map(&:first).uniq.sort
    assert_equal %i[confirm grade grade_activity], writes
  end
end
