require "test_helper"

class DevopsRoutesTest < ActionDispatch::IntegrationTest
  test "devops web routes are removed" do
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/devops")
    end

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/devops/cycle")
    end
  end
end
