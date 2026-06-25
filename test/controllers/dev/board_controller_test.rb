require "test_helper"
require "minitest/mock"

# Dev::BoardController — local-only toys that spawn / advance / remove a throwaway
# fixture task to demo the live /deployments board. Gated to Rails.env.local?
# (development + test), so the happy paths run here; production is guarded.
class Dev::BoardControllerTest < ActionDispatch::IntegrationTest
  def fixtures
    Task.where("metadata ->> 'dev_fixture' = 'true'").order(created_at: :desc)
  end

  test "[integration] generate spawns a marked fixture in designed" do
    assert_difference -> { fixtures.count }, 1 do
      post dev_board_generate_path
    end
    assert_response :success
    assert_equal "designed", fixtures.first.stage
  end

  test "[integration] move advances the latest fixture one deploy stage" do
    post dev_board_generate_path
    task = fixtures.first
    assert_equal "designed", task.stage
    post dev_board_move_path
    assert_response :success
    assert_equal "building", task.reload.stage
  end

  test "[integration] delete removes the latest fixture" do
    post dev_board_generate_path
    assert_difference -> { fixtures.count }, -1 do
      post dev_board_delete_path
    end
    assert_response :no_content
  end

  test "[integration] move/delete never touch a real (non-fixture) task" do
    real = Task.create!(title: "a real task", stage: "designed")
    post dev_board_move_path    # no fixtures present → no-op
    post dev_board_delete_path  # no fixtures present → no-op
    assert Task.exists?(real.id), "a real task must never be deleted"
    assert_equal "designed", real.reload.stage, "a real task must never be moved"
  end

  test "[unit] the endpoints are forbidden outside development/test (production)" do
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      post dev_board_generate_path
      assert_response :forbidden
    end
  end
end
