require "test_helper"

# Integration tier: a shiny mascot's board card renders the SHINY sprite in its
# build-lane crew circle, through the real /tasks board render path
# (build_step_columns → task_mascot_face → Pokemon#display_sprite).
class BoardCardShinyMascotTest < ActionDispatch::IntegrationTest
  setup do
    Pokemon.create!(dex: 303, name: "Gyarados", slug: "gyarados", types: %w[water flying],
                    generation: 1,
                    sprite_url: "https://img.test/normal-sprite.png",
                    shiny_sprite_url: "https://img.test/shiny-sprite.png")
  end

  test "tasks board card wears the shiny sprite for a shiny mascot" do
    gyarados = Pokemon.find_by!(slug: "gyarados")
    task = Pokemon.stub(:draw, gyarados) do
      Pokemon.stub(:roll_shiny?, true) do
        Task.create!(title: "Shiny mascot board card", stage: "building")
      end
    end
    assert_predicate task, :mascot_shiny?

    get tasks_path
    assert_response :success
    assert_select "#card-#{task.slug}" do
      assert_select "img[src='https://img.test/shiny-sprite.png']"
      assert_select "img[src='https://img.test/normal-sprite.png']", count: 0
      assert_select "[data-test='avatar-shiny-badge']", { minimum: 1, text: "✨" }
    end
  end

  test "stacked shiny crew shows only the top shiny badge" do
    gyarados = Pokemon.find_by!(slug: "gyarados")
    task = Task.create!(title: "Stacked shiny mascot board card", stage: "submitted",
                        metadata: { "devops" => { "mascot" => gyarados.slug, "mascot_shiny" => true } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 3.hours.ago)
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600)

    get deployments_path
    assert_response :success
    assert_select "#card-#{task.slug} [data-test='crew-cluster'][data-lane='build']" do
      assert_select "img[src='https://img.test/shiny-sprite.png']", count: 3
      assert_select "[data-test='avatar-shiny-badge']", count: 1, text: "✨"
    end
  end

  test "tasks board card keeps the normal sprite for an ordinary mascot" do
    gyarados = Pokemon.find_by!(slug: "gyarados")
    task = Pokemon.stub(:draw, gyarados) do
      Pokemon.stub(:roll_shiny?, false) do
        Task.create!(title: "Plain mascot board card", stage: "building")
      end
    end
    assert_not task.mascot_shiny?

    get tasks_path
    assert_response :success
    assert_select "#card-#{task.slug}" do
      assert_select "img[src='https://img.test/normal-sprite.png']"
      assert_select "img[src='https://img.test/shiny-sprite.png']", count: 0
      assert_select "[data-test='avatar-shiny-badge']", count: 0
    end
  end
end
