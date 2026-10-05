require "test_helper"

# [unit] the heartbeat surface's read/write split, pinned to the route table. The
# controller skips the login for READ_ACTIONS only and demands an admin for every
# other action, so a write is admin-gated by construction: this guard fails the
# day a non-GET route points at an action listed as a read, or a read action grows
# a non-GET route.
class HeartbeatControllerTest < ActiveSupport::TestCase
  def heartbeat_routes
    Rails.application.routes.routes.select { |r| r.defaults[:controller] == "heartbeat" }
                                   .map { |r| [r.defaults[:action].to_sym, r.verb] }
  end

  test "[unit] every heartbeat route is covered and the writes are not reads" do
    assert heartbeat_routes.any?, "the route table names the heartbeat controller"

    heartbeat_routes.each do |action, verb|
      if verb == "GET"
        assert_includes HeartbeatController::READ_ACTIONS, action,
                        "GET heartbeat##{action} is a read and belongs in READ_ACTIONS"
      else
        assert_not_includes HeartbeatController::READ_ACTIONS, action,
                            "#{verb} heartbeat##{action} is a write and must not skip the admin gate"
      end
    end
  end

  test "[unit] the write actions are the grade, activity grade and confirm endpoints" do
    writes = heartbeat_routes.reject { |_, verb| verb == "GET" }.map(&:first).uniq.sort
    assert_equal %i[confirm grade grade_activity], writes
  end
end
