require "test_helper"

class DevopsRoutesTest < ActionDispatch::IntegrationTest
  # The old DevOps cycle web pages stay removed. /devops itself is the board home since
  # devops-namespace (2026-11-07), not the retired cycle page.
  test "devops cycle web route stays removed; /devops is the board home" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/devops/cycle")
    end

    assert_equal({ controller: "tasks", action: "deployments" }, Rails.application.routes.recognize_path("/devops"))
  end
end
