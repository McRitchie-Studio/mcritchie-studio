require "test_helper"

class DevopsControllerTest < ActionDispatch::IntegrationTest
  test "index requires login" do
    get devops_path

    assert_redirected_to login_path
  end

  test "index requires admin" do
    log_in_as users(:viewer)

    get devops_path

    assert_redirected_to root_path
  end

  test "admin can view test suite catalog" do
    log_in_as users(:alex)

    get devops_path

    assert_response :success
    assert_select "h2", "DevOps Test Suites"
    assert_select "h3", "McRitchie Studio"
    assert_select "h3", "Turf Monster"
    assert_includes response.body, "QA devnet mutating smoke"
  end

  test "renders worktrees and slots panel from registry fixture" do
    WorktreeRegistry.registry_path = file_fixture("worktree_registry.json").to_s
    log_in_as users(:alex)

    get devops_path

    assert_response :success
    # Test-suite catalog still renders (no regression).
    assert_select "h2", "DevOps Test Suites"
    # Worktrees & Slots panel.
    assert_select "h2", /Worktrees/
    # Capacity band.
    assert_includes response.body, "Redis Slot Capacity"
    assert_includes response.body, "Physical Max"
    # At least one worktree row.
    assert_includes response.body, "devops-worktrees-slots-panel"
    assert_includes response.body, "feat/devops-worktrees-slots-panel"
    # Badges + linked port.
    assert_includes response.body, "MERGED"
    assert_includes response.body, "DIRTY"
    assert_select "a[href=?]", "http://localhost:3007"
  ensure
    WorktreeRegistry.reset_registry_path!
  end

  test "empty state when registry missing" do
    WorktreeRegistry.registry_path = Rails.root.join("tmp", "does-not-exist-registry.json").to_s
    log_in_as users(:alex)

    get devops_path

    assert_response :success
    assert_includes response.body, "No worktree registry found"
  ensure
    WorktreeRegistry.reset_registry_path!
  end

  # === In-app SOP viewer (#cycle) ===

  test "cycle requires login" do
    get devops_cycle_path

    assert_redirected_to login_path
  end

  test "cycle requires admin" do
    log_in_as users(:viewer)

    get devops_cycle_path

    assert_redirected_to root_path
  end

  test "admin gets 200 and the self-contained viewer renders without app layout" do
    log_in_as users(:alex)

    get devops_cycle_path

    assert_response :success
    # The page brings its own <html>/<title> (layout: false).
    assert_includes response.body, "<!doctype html>"
    assert_select "title", "McRitchie DevOps Cycle — SOP Viewer"
    assert_select "h1", /McRitchie DevOps Cycle/
  end
end
