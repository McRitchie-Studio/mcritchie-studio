require "test_helper"

# [integration] Guards MS's adoption of studio-engine's living style guide.
# The engine bundles /admin/style (StyleController#index, helper admin_style_path)
# with four sections — Theme · Modals · Tricks · Tasks — and MS's admin sidebar
# links straight to it. This confirms the engine route resolves in the host app,
# renders for an admin, and stays admin-gated. It also pins the 0.22 refresh: the
# confetti/pulse tricks and the leveling-OFF modal demos MS ships (no :leveling).
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

  # studio-engine 0.22 refresh: the confetti/pulse tricks (ported from Turf
  # Monster) and the leveling-activity modal demos. MS ships :leveling OFF, so
  # it gets the PLAIN modal variants + the tricks, with the leveling specimens
  # present-but-flagged (disabled, never hidden).
  test "admin/style shows the 0.22 confetti/pulse tricks and the leveling-off modal demos" do
    log_in_as users(:alex)

    get admin_style_path
    assert_response :success

    # Confetti — the two window.studioConfetti entrypoints fire from specimen buttons.
    assert_includes @response.body, "window.studioConfetti.burst",
      "expected the studioConfetti.burst trick specimen"
    assert_includes @response.body, "window.studioConfetti.cannons()",
      "expected the studioConfetti.cannons trick specimen"
    # Pulse — the .pulse-cta attention beat renders as a real button.
    assert_select "button.pulse-cta", { minimum: 1 }, "expected a .pulse-cta specimen button"

    # Leveling OFF for MS: the specimens must render present-but-flagged, not hidden.
    assert_not Studio.feature?(:leveling), "MS must ship leveling OFF for this spec"
    assert_includes @response.body, "disabled on this app",
      "expected the leveling trick group flagged disabled"

    # Leveling-off modal demos: the PLAIN change-username + quest activities
    # (no quest pill, no seeds — same primitive, flag off).
    assert_includes @response.body, "$store.dsModals.open('change-username-plain')",
      "expected the plain (leveling-off) change-username modal demo"
    assert_includes @response.body, "$store.dsModals.open('quest-activity-plain')",
      "expected the plain (leveling-off) quest-activity modal demo"
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
