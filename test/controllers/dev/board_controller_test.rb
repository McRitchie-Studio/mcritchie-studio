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

  test "[integration] ship_release ships the active release" do
    rel = Release.open!
    post dev_board_ship_release_path
    assert_response :no_content
    assert_equal "shipped", rel.reload.state
    assert_nil Release.current, "shipping the active release clears the Next slot"
  end

  test "[integration] ship_release opens and ships a fixture when none is active" do
    assert_nil Release.current
    assert_difference -> { Release.where(state: "shipped").count }, 1 do
      post dev_board_ship_release_path
    end
    assert_response :no_content
  end

  # --- deployment-step toys (open / advance / reset a fixture RELEASE) ---------

  def fixture_releases
    Release.where("metadata ->> 'dev_fixture' = 'true'")
  end

  def fixture_release
    fixture_releases.order(created_at: :desc).first
  end

  # The live tracker derives its done_count from durable release writes — assert
  # against the SAME helper the view reads so the toy provably steps the tracker.
  def done_count(release)
    ApplicationController.helpers.release_tracker_done_count(release)
  end

  test "[integration] open_release opens a clean fixture release at tracker step 0" do
    post dev_board_open_release_path
    assert_response :no_content

    rel = fixture_release
    assert_not_nil rel, "open_release spawns a marked fixture release"
    assert_equal "assembling", rel.state
    assert_equal 0, done_count(rel), "a fresh release sits at Testing (done_count 0)"
  end

  test "[integration] advance_release steps the fixture release's tracker done_count 0 to 5" do
    post dev_board_open_release_path
    rel = fixture_release
    assert_equal 0, done_count(rel)

    post dev_board_advance_release_path # 0 -> 1: adopt a member
    assert_equal 1, done_count(rel.reload)
    assert rel.tasks.any?, "step 1 adopts a member task"

    post dev_board_advance_release_path # 1 -> 2: QA deploy
    assert_equal 2, done_count(rel.reload)
    assert rel.qa_url.present?, "step 2 records a QA url"

    post dev_board_advance_release_path # 2 -> 3: assembled
    assert_equal 3, done_count(rel.reload)
    assert_equal "assembled", rel.state

    post dev_board_advance_release_path # 3 -> 4: confirmed
    assert_equal 4, done_count(rel.reload)
    assert rel.confirmed_at.present?, "step 4 records confirmation"

    post dev_board_advance_release_path # 4 -> 5: shipped
    assert_equal 5, done_count(rel.reload)
    assert_equal "shipped", rel.state
  end

  test "[integration] reset_release clears the fixture release and its members" do
    post dev_board_open_release_path
    post dev_board_advance_release_path # adopt a fixture member task
    assert fixture_releases.exists?
    fixture_members = Task.where("metadata ->> 'dev_fixture' = 'true'").where.not(release_slug: nil)
    assert fixture_members.exists?, "a fixture member is attached after advancing"

    post dev_board_reset_release_path
    assert_response :no_content
    assert_not fixture_releases.exists?, "reset tears down the fixture release"
    assert_not fixture_members.exists?, "reset also removes the fixture member tasks"
  end

  test "[unit] the release toys are forbidden outside development/test (production)" do
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      post dev_board_open_release_path
      assert_response :forbidden
      post dev_board_advance_release_path
      assert_response :forbidden
      post dev_board_reset_release_path
      assert_response :forbidden
    end
  end
end
