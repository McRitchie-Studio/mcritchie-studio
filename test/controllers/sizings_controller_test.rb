require "test_helper"

class SizingsControllerTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @task = tasks(:new_task)
  end

  # === GET show ===

  test "show renders sizing page for an admin" do
    get task_sizing_path(@task)
    assert_response :success
    assert_select "h2", @task.title
  end

  test "show renders all four size inputs" do
    get task_sizing_path(@task)
    assert_response :success
    %i[pm_size po_size dev_size actual_size].each do |field|
      assert_select "select[name='task[#{field}]']"
    end
  end

  test "show renders requires_migration checkbox" do
    get task_sizing_path(@task)
    assert_response :success
    assert_select "input[type='checkbox'][name='task[requires_migration]']"
  end

  test "show redirects when task not found" do
    get "/tasks/does-not-exist/sizing"
    assert_redirected_to tasks_path
  end

  # === PATCH update (admin) ===

  test "update persists all four sizes as admin" do
    log_in_as(@admin)
    patch task_sizing_path(@task),
          params: { task: { pm_size: "small", po_size: "medium", dev_size: "large", actual_size: "xl" } }
    assert_redirected_to task_sizing_path(@task)
    @task.reload
    assert_equal "small", @task.pm_size
    assert_equal "medium", @task.po_size
    assert_equal "large", @task.dev_size
    assert_equal "xl", @task.actual_size
  end

  test "update persists requires_migration flag" do
    log_in_as(@admin)
    patch task_sizing_path(@task), params: { task: { requires_migration: "1" } }
    assert_redirected_to task_sizing_path(@task)
    @task.reload
    assert_equal true, @task.requires_migration
  end

  test "update rejects invalid size" do
    log_in_as(@admin)
    patch task_sizing_path(@task), params: { task: { po_size: "huge" } }
    assert_redirected_to task_sizing_path(@task)
    @task.reload
    assert_nil @task.po_size
  end

  test "update via JSON returns task" do
    log_in_as(@admin)
    patch task_sizing_path(@task, format: :json),
          params: { task: { po_size: "medium" } }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "medium", body["po_size"]
  end

  # === Auth enforcement ===

  test "update requires admin" do
    log_in_as(@viewer)
    patch task_sizing_path(@task), params: { task: { po_size: "medium" } }
    assert_response :redirect
    @task.reload
    assert_nil @task.po_size
  end

  test "update requires login" do
    reset!
    patch task_sizing_path(@task), params: { task: { po_size: "medium" } }
    assert_response :redirect
    @task.reload
    assert_nil @task.po_size
  end

  # === Strong params ===

  test "update ignores params outside the sizing surface" do
    log_in_as(@admin)
    original_title = @task.title
    patch task_sizing_path(@task),
          params: { task: { po_size: "medium", title: "Hijacked title", stage: "archived" } }
    assert_redirected_to task_sizing_path(@task)
    @task.reload
    assert_equal "medium", @task.po_size
    assert_equal original_title, @task.title
    assert_not_equal "archived", @task.stage
  end
end
