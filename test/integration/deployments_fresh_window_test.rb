require "test_helper"

# Integration: /deployments carries the fresh-deploy glow window END TO END.
# The Last Release card self-describes its window (data-fresh-window-ms) and
# the FX layer's JS timer renders from the SAME helper value, so the
# release-ship e2e spec budgets its waits from the page itself instead of
# racing a hardcoded 8s wall-clock window (task stabilize-release-ship-spec).
class DeploymentsFreshWindowTest < ActionDispatch::IntegrationTest
  test "[integration] a fresh ship renders the glow state and self-describes its window" do
    rel = Release.open!
    rel.ship!(by: "test")

    get deployments_path
    assert_response :success

    assert_select "#last-release[data-fresh-deploy='true'][data-fresh-window-ms='8000']"
    assert_includes response.body, "const FRESH_DEPLOY_MS = 8000"
  end

  test "[integration] the injected window drives the card and the FX timer together" do
    rel = nil
    travel_to 9.seconds.ago do
      rel = Release.open!
      rel.ship!(by: "test")
    end

    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      get deployments_path
      assert_response :success

      # +9s: stale under the production default, FRESH under the injected
      # window — card state and client timer widen from one value.
      assert_select "#last-release[data-fresh-deploy='true'][data-fresh-window-ms='20000']"
      assert_includes response.body, "const FRESH_DEPLOY_MS = 20000"
    end
  end
end
