require "test_helper"

# [integration] the toast harness is gone: no page, no flash route, no link-tree
# entry. It skipped the login and echoed a visitor's `message` param into a flash,
# so it has no place in a production route table.
class ToastTestRemovedTest < ActionDispatch::IntegrationTest
  test "[integration] /toast_test and /toast_test/flash answer 404" do
    get "/toast_test"
    assert_response :not_found

    post "/toast_test/flash", params: { type: "alert", message: "injected" }
    assert_response :not_found
  end

  test "[integration] no route, helper or controller names the harness" do
    assert_not Rails.application.routes.url_helpers.respond_to?(:toast_test_path)
    assert_not Rails.application.routes.url_helpers.respond_to?(:toast_test_flash_path)
    assert_not Object.const_defined?(:ToastTestController)
  end
end
