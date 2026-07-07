require "test_helper"
require "minitest/mock"

# Dev::BoardController — local-only toys that spawn / advance / remove a throwaway
# fixture task to demo the live /deployments board. Gated to Rails.env.local?
# (development + test), so the happy paths run here; production is guarded.
class Dev::BoardControllerTest < ActionDispatch::IntegrationTest
  def fixtures
    Task.where("metadata ->> 'dev_fixture' = 'true'").order(created_at: :desc)
  end

  def fixture_pokemon
    enumeral = Studio::Enumeral.find_or_initialize_by(category: "pokemon_type", key: "electric")
    enumeral.update!(color: "#F7D02C", metadata: { "emoji" => "⚡" })
    Pokemon.create!(dex: 998, name: "Sparkster", slug: "fixture-sparkster",
                    types: %w[electric], generation: 1,
                    sprite_url: "normal-sprite.png", shiny_sprite_url: "shiny-sprite.png")
  end

  test "[integration] generate spawns a marked fixture in designed" do
    assert_difference -> { fixtures.count }, 1 do
      post dev_board_generate_path
    end
    assert_response :success
    assert_equal "designed", fixtures.first.stage
  end

  test "[integration] generate stamps shiny metadata on fixture mascots" do
    pokemon = fixture_pokemon

    Pokemon.stub(:draw, pokemon) do
      Pokemon.stub(:roll_shiny?, true) do
        post dev_board_generate_path
      end
    end

    assert_response :success
    task = fixtures.first
    assert_equal pokemon.slug, task.devops["mascot"]
    assert_predicate task, :mascot_shiny?
    assert_equal "#F7D02C", task.devops["mascot_color"]
    assert_equal "⚡✨", task.devops["mascot_emoji"]
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
    # Resolve the path BEFORE stubbing the env: routes draw lazily, and the dev
    # namespace only draws when Rails.env.local? — if this test runs first in the
    # process, drawing under the stub would strip dev_board_* for every later test.
    path = dev_board_generate_path
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      post path
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

  # The live tracker reads the release's stage stamps — assert against the SAME
  # model reads the view uses so the toy provably steps the tracker.
  def tracker_states(release)
    ApplicationController.helpers.release_tracker_steps(release).map { |step| step[:state] }
  end

  test "[integration] open_release opens a clean fixture release with an untouched timeline" do
    post dev_board_open_release_path
    assert_response :no_content

    rel = fixture_release
    assert_not_nil rel, "open_release spawns a marked fixture release"
    assert_equal "assembling", rel.state
    assert_nil rel.current_stage, "a fresh fixture has no stage stamped"
    assert_equal %i[pending pending pending pending pending], tracker_states(rel)
  end

  test "[integration] open_release stamps shiny metadata on fixture releases" do
    pokemon = fixture_pokemon

    Pokemon.stub(:draw, pokemon) do
      Pokemon.stub(:roll_shiny?, true) do
        post dev_board_open_release_path
      end
    end

    assert_response :no_content
    devops = fixture_release.metadata.fetch("devops")
    assert_equal pokemon.slug, devops["mascot"]
    assert_equal true, devops["mascot_shiny"]
    assert_equal "⚡✨", devops["mascot_emoji"]
  end

  test "[integration] advance_release stamps stage by stage, shipping on the terminal one" do
    post dev_board_open_release_path
    rel = fixture_release

    post dev_board_advance_release_path # → testing
    assert_equal "testing", rel.reload.current_stage
    assert_equal %i[active pending pending pending pending], tracker_states(rel)

    post dev_board_advance_release_path # → assembling (adopts a member for the card pill)
    assert_equal "assembling", rel.reload.current_stage
    assert rel.tasks.any?, "the assembling frame adopts a member task"
    assert_equal %i[complete active pending pending pending], tracker_states(rel)

    post dev_board_advance_release_path # → assembled
    post dev_board_advance_release_path # → qa_deploying
    assert_equal %i[complete complete active pending pending], tracker_states(rel.reload)

    post dev_board_advance_release_path # → qa_deployed: Live on QA, Confirming stays DARK
    assert_equal %i[complete complete complete pending pending], tracker_states(rel.reload),
                 "the Steffon→Avi handoff gap renders on the toy too"

    post dev_board_advance_release_path # → confirming
    assert_equal %i[complete complete complete active pending], tracker_states(rel.reload)

    post dev_board_advance_release_path # → confirmed
    post dev_board_advance_release_path # → prod_deploying
    assert_equal %i[complete complete complete complete active], tracker_states(rel.reload)

    # Reaching the terminal stage ships in ONE advance — no confirmed-but-unshipped
    # pause. The release goes straight to shipped and becomes the Last Release.
    post dev_board_advance_release_path # → shipped
    assert_equal "shipped", rel.reload.state
    assert_equal %i[complete complete complete complete complete], tracker_states(rel)
    assert_equal rel, Release.last_shipped, "shipping the fixture creates the Last Release"
    assert_nil Release.current, "shipping clears the Next Release slot"
  end

  test "[integration] advance_release steps an existing active release instead of opening a second one" do
    rel = Release.open!(branch: "release/local-preview-active")

    assert_no_difference -> { fixture_releases.count } do
      post dev_board_advance_release_path
    end

    assert_response :no_content
    assert_equal "testing", rel.reload.current_stage
    assert_equal %i[active pending pending pending pending], tracker_states(rel)
  end

  test "[integration] fixture release members stamp shiny metadata" do
    pokemon = fixture_pokemon
    post dev_board_open_release_path

    Pokemon.stub(:draw, pokemon) do
      Pokemon.stub(:roll_shiny?, true) do
        post dev_board_advance_release_path # → testing
        post dev_board_advance_release_path # → assembling: adopts a member
      end
    end

    assert_response :success
    member = Task.where("metadata ->> 'dev_fixture' = 'true'").where.not(release_slug: nil).first
    assert_not_nil member
    assert_equal pokemon.slug, member.devops["mascot"]
    assert_predicate member, :mascot_shiny?
    assert_equal "⚡✨", member.devops["mascot_emoji"]
  end

  test "[integration] reset_release clears the fixture release and its members" do
    post dev_board_open_release_path
    post dev_board_advance_release_path # → testing
    post dev_board_advance_release_path # → assembling: adopts a fixture member task
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
