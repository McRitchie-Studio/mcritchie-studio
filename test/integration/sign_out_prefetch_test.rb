require "test_helper"

# [component] A speculative fetch of the sign-out (GET /logout) leaves the session
# as it was: Turbo's hover prefetch (X-Sec-Purpose: prefetch) and the browser's
# own (Sec-Purpose: prefetch) get a 204 and no Set-Cookie, and the next request is
# still signed in. A real visit still signs out. ApplicationController
# #refuse_prefetched_sign_out (task build-funnel-held-message-cause).
class SignOutPrefetchTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.find_by(role: "admin") || User.create!(email: "prefetch-admin@example.com", name: "Prefetch Admin", role: "admin")
  end

  def signed_in?
    get "/build"
    assert_response :success
    response.body.include?("Toggle admin menu")
  end

  test "a Turbo prefetch of /logout is answered 204 and signs nobody out" do
    log_in_as(@admin)
    assert signed_in?, "the admin is signed in before the prefetch"

    get "/logout", headers: { "X-Sec-Purpose" => "prefetch" }
    assert_response :no_content
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"], "a prefetch writes no session cookie"

    assert signed_in?, "the prefetch left the session as it was"
  end

  test "the browser's own Sec-Purpose prefetch is refused the same way" do
    log_in_as(@admin)
    get "/logout", headers: { "Sec-Purpose" => "prefetch;prerender" }
    assert_response :no_content
    assert signed_in?
  end

  test "a real visit to /logout still signs out" do
    log_in_as(@admin)
    get "/logout"
    assert_redirected_to login_path
    refute signed_in?, "a click on Log out ends the session"
  end

  test "prefetch_request? reads only the purpose headers" do
    request = ->(headers) { ActionDispatch::Request.new(Rack::MockRequest.env_for("/logout", headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })) }
    assert ApplicationController.prefetch_request?(request.call("X-Sec-Purpose" => "prefetch"))
    assert ApplicationController.prefetch_request?(request.call("Purpose" => "prefetch"))
    refute ApplicationController.prefetch_request?(request.call({}))
    refute ApplicationController.prefetch_request?(request.call("Sec-Purpose" => "prerendering-is-not-it"))
  end
end
