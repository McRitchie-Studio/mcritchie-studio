require "test_helper"

# [component] Session entry launcher — the terminal-styled chooser for how you
# enter a session. ui-only shape: assert the rendered avenues and that the Alex
# avenue targets the learning-heartbeat path.
class SessionEntryLauncherTest < ActionDispatch::IntegrationTest
  test "launcher renders for anyone (no auth) with the three avenues" do
    get launcher_path

    assert_response :success
    assert_select "[data-avenue=session]", 1
    assert_select "[data-avenue=avi]", 1
    assert_select "[data-avenue=alex]", 1
    assert_match "Session agent", response.body
    assert_match "Avi", response.body
    assert_match "Alex", response.body
  end

  test "selecting Alex targets the learning heartbeat path" do
    get launcher_path

    assert_response :success
    assert_select "a[data-avenue=alex][href=?]", alex_heartbeat_path
    assert_select "a[data-avenue=alex][data-avenue-target=?]", "learning-heartbeat"
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

  test "alex heartbeat route renders a marked placeholder" do
    get alex_heartbeat_path

    assert_response :success
    assert_select "[data-placeholder=alex-heartbeat]", 1
    assert_select "a[href=?]", launcher_path
  end
end
