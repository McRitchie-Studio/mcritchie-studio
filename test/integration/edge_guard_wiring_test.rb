# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/edge_guard")

# [integration] EdgeGuard against the REAL middleware stack.
#
# test/lib/edge_guard_test.rb proves the class decides correctly in isolation; a correct
# class that is not mounted, or is mounted behind Rack::Attack, protects nothing. These
# cases assert the wiring: that it is registered, that it sits in front of the throttles
# whose per-IP keys depend on it, and that a request driven through the actual
# application is refused or admitted as intended.
class EdgeGuardWiringTest < ActionDispatch::IntegrationTest
  SECRET = "integration-edge-secret"

  def stack
    Rails.application.middleware.map(&:klass)
  end

  test "EdgeGuard is mounted in the application middleware stack" do
    assert_includes stack, EdgeGuard
  end

  test "EdgeGuard runs ahead of Rack::Attack so throttles key on the real visitor" do
    assert_includes stack, Rack::Attack, "guard ordering is only meaningful with the throttles mounted"

    assert stack.index(EdgeGuard) < stack.index(Rack::Attack),
           "EdgeGuard must precede Rack::Attack, or every throttle keys on the CDN edge address"
  end

  test "EdgeGuard is the outermost middleware" do
    assert_equal EdgeGuard, stack.first,
                 "bypass traffic should be refused before host authorization, logging, or sessions"
  end

  # The stack as BUILT is unarmed (no EDGE_SECRET in the test environment), which is the
  # same state it deploys in — so an ordinary request must be completely unaffected.
  test "an ordinary request is untouched while the guard is unarmed" do
    get "/up"

    assert_response :success
  end

  # Drive a full request through an ARMED guard wrapped around the real application, so
  # the refusal is proven against the actual stack rather than a stub.
  test "an armed guard refuses a direct-to-origin request to the real app" do
    status, _headers, body = armed.call(rack_env_for("/tasks"))

    assert_equal 403, status
    assert_match(/only through its edge/, body.each.to_a.join)
  end

  test "an armed guard admits a request from the edge and the app still renders" do
    status, = armed.call(rack_env_for("/tasks", "HTTP_X_EDGE_SECRET" => SECRET))

    assert_equal 200, status, "edge traffic must reach the app normally"
  end

  test "an armed guard still lets the platform health check through" do
    status, = armed.call(rack_env_for("/up"))

    assert_equal 200, status
  end

  private

  def armed
    EdgeGuard.new(Rails.application, secret: SECRET)
  end

  def rack_env_for(path, headers = {})
    Rack::MockRequest.env_for(
      "https://#{Rails.application.config.hosts.first || 'www.example.com'}#{path}",
      "HTTPS" => "on"
    ).merge(headers)
  end
end
