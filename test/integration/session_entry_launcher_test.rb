require "test_helper"

# [component] Session entry launcher — the terminal-styled chooser for how you
# enter a session. ui-only shape: assert the rendered avenues and that the Ritch
# avenue targets the learning-heartbeat path.
class SessionEntryLauncherTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  test "launcher renders for an admin with the three avenues" do
    get launcher_path

    assert_response :success
    assert_select "[data-avenue=session]", 1
    assert_select "[data-avenue=avi]", 1
    assert_select "[data-avenue=ray]", 1
    assert_match "Session agent", response.body
    assert_match "Avi", response.body
    assert_match "Ritch", response.body
  end

  test "selecting Ritch targets the learning heartbeat path" do
    get launcher_path

    assert_response :success
    assert_select "a[data-avenue=ray][href=?]", mason_heartbeat_path
    assert_select "a[data-avenue=ray][data-avenue-target=?]", "learning-heartbeat"
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

  test "ray heartbeat route now renders the trajectory view (no longer a placeholder)" do
    get mason_heartbeat_path

    assert_response :success
    assert_select "[data-test=heartbeat]", 1
    assert_select "[data-placeholder=mason-heartbeat]", 0
  end
end
