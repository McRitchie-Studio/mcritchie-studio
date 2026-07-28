require "test_helper"

# [integration] Guards MS's adoption of studio-engine 0.18's living style guide.
# The engine bundles /admin/style (StyleController#index, helper admin_style_path)
# with four sections — Theme · Modals · Tricks · Tasks — and MS's admin sidebar
# links straight to it. This confirms the engine route resolves in the host app,
# renders for an admin, and stays admin-gated.
class AdminStylePageTest < ActionDispatch::IntegrationTest
  test "admin gets /admin/style with the Theme, Modals, Tricks and Tasks sections" do
    log_in_as users(:alex)

    get admin_style_path
    assert_response :success

    assert_select "#theme",  { count: 1 }, "expected the Theme section"
    assert_select "#modals", { count: 1 }, "expected the Modals section"
    assert_select "#tricks", { count: 1 }, "expected the Tricks section"
    assert_select "#tasks",  { count: 1 }, "expected the Tasks section"
  end

  test "the admin sidebar Design System link points at /admin/style" do
    log_in_as users(:alex)

    get dashboard_path
    assert_response :success

    assert_select "#studio-link-sidebar a[href=?]", admin_style_path
    # It must not regress to the legacy design_system route (which only redirects).
    assert_select "#studio-link-sidebar a[href=?]", admin_design_system_path, count: 0
  end

  test "the canonical admin_style route resolves and /admin/design_system redirects to it" do
    assert_equal "/admin/style", admin_style_path

    get admin_design_system_path
    assert_redirected_to "/admin/style"
  end

  test "a non-admin cannot reach /admin/style" do
    log_in_as users(:viewer)

    get admin_style_path
    assert_response :redirect
  end
end
