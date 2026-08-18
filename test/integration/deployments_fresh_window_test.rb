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

    assert_select "#last-release[data-fresh-deploy='true'][data-fresh-window-ms='60000']"
    assert_includes response.body, "const FRESH_DEPLOY_MS = 60000"
  end

  # THE OVERRIDE IS NOW THE SHORTER WINDOW, so this test discriminates in the opposite
  # direction from the one it was written in. The production window went 8s -> 60s and
  # the e2e override stayed 20s, which INVERTED the old premise ("+9s: stale under the
  # default, fresh under the injection") — 9s is fresh under both now, and the assertion
  # would have passed while proving nothing. A ship 30s old is the discriminating case
  # today: FRESH under the 60s default, STALE under the 20s injection. The property is
  # unchanged and is the only reason this test exists — the card's rendered state and the
  # client's timer both come from ONE value, so they can never disagree about when the
  # glow ends.
  test "[integration] the injected window drives the card and the FX timer together" do
    travel_to 30.seconds.ago do
      Release.open!.ship!(by: "test")
    end

    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      get deployments_path
      assert_response :success

      assert_select "#last-release[data-fresh-deploy='false'][data-fresh-window-ms='20000']"
      assert_includes response.body, "const FRESH_DEPLOY_MS = 20000"
    end

    # And the same 30s-old ship IS still fresh under the production default — the half
    # that proves the assertion above is reading the injection and not just the clock.
    with_env("FRESH_DEPLOY_WINDOW_MS", nil) do
      get deployments_path
      assert_response :success

      assert_select "#last-release[data-fresh-deploy='true'][data-fresh-window-ms='60000']"
    end
  end
end
