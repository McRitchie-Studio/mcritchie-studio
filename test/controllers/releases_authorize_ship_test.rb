require "test_helper"

# [integration] POST /deployments/:slug/ship_authorization — the Approve button's
# grant (design section 6). Admin-gated; one idempotent event; JSON for the
# card's fetch, a redirect for a plain form post.
class ReleasesAuthorizeShipTest < ActionDispatch::IntegrationTest
  setup do
    @release = Release.open!
    @release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                           metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601 })
    @admin = User.create!(email: "windows-admin@example.com", name: "Windows Admin", role: "admin")
    @viewer = User.create!(email: "windows-viewer@example.com", name: "Windows Viewer", role: "user")
  end

  test "[integration] an admin's approve records the one grant and answers JSON" do
    log_in_as(@admin)

    assert_difference -> { ReleaseEvent.where(step: "ship_authorized", status: "completed").count }, 1 do
      post authorize_ship_deployment_path(@release.slug), headers: { "Accept" => "application/json" }
    end
    assert_response :success
    body = response.parsed_body.fetch("data")
    assert_equal true, body["granted"]
    assert_equal "windows-admin@example.com", body["granted_by"]
    assert_equal "web", body["granted_via"]
    assert_nil body["window_ends_at"], "the window closes on the grant"

    assert_no_difference -> { ReleaseEvent.count } do
      post authorize_ship_deployment_path(@release.slug), headers: { "Accept" => "application/json" }
    end
    assert_response :success
  end

  test "[integration] a plain form post redirects to the board with a notice" do
    log_in_as(@admin)
    post authorize_ship_deployment_path(@release.slug)
    assert_redirected_to deployments_path
    assert @release.reload.ship_authorization_granted?
  end

  test "[integration] a signed-in non-admin and a guest are refused and grant nothing" do
    log_in_as(@viewer)
    post authorize_ship_deployment_path(@release.slug), headers: { "Accept" => "application/json" }
    assert_response :redirect
    refute @release.reload.ship_authorization_granted?

    reset!
    post authorize_ship_deployment_path(@release.slug), headers: { "Accept" => "application/json" }
    assert_response :unauthorized, "a guest's JSON post is refused outright by the engine's authentication"
    refute @release.reload.ship_authorization_granted?
  end

  test "[integration] an unknown release is a 404 for JSON" do
    log_in_as(@admin)
    post authorize_ship_deployment_path("rel-nope"), headers: { "Accept" => "application/json" }
    assert_response :not_found
  end
end
