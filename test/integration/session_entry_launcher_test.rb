require "test_helper"

# [component] Session entry launcher — the terminal-styled chooser for how you
# enter a session. ui-only shape: assert the rendered avenues and that the Xan
# avenue targets the learning-heartbeat path.
class SessionEntryLauncherTest < ActionDispatch::IntegrationTest
  test "launcher renders for anyone (no auth) with the three avenues" do
    get launcher_path

    assert_response :success
    assert_select "[data-avenue=session]", 1
    assert_select "[data-avenue=avi]", 1
    assert_select "[data-avenue=xan]", 1
    assert_match "Session agent", response.body
    assert_match "Avi", response.body
    assert_match "Xan", response.body
  end

  test "selecting Xan targets the learning heartbeat path" do
    get launcher_path

    assert_response :success
    assert_select "a[data-avenue=xan][href=?]", xan_heartbeat_path
    assert_select "a[data-avenue=xan][data-avenue-target=?]", "learning-heartbeat"
  end

  test "Session agent and Avi are visibly coming-soon stubs (not links)" do
    get launcher_path

    assert_response :success
    # Stubs render as buttons, not anchors, so they cannot navigate yet.
    assert_select "button[data-avenue=session]", 1
    assert_select "button[data-avenue=avi]", 1
    assert_select "a[data-avenue=session]", 0
    assert_select "a[data-avenue=avi]", 0
  end

  test "xan heartbeat route now renders the trajectory view (no longer a placeholder)" do
    get xan_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat]", 1
    assert_select "[data-placeholder=xan-heartbeat]", 0
  end
end
