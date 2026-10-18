require "test_helper"

# [unit] The app chat's Building · Releasing · Deploying pills, from the build
# task's stage (.agents/epics/build-with-ray-v2.md, section 6).
class AppDevopsStagesTest < ActiveSupport::TestCase
  def states(...) = AppDevopsStages.from(...).map { |stage| [ stage.key, stage.state ] }.to_h

  test "every stage up to review is Building, live" do
    %w[designed building submitted reviewed].each do |stage|
      assert_equal({ "building" => :live, "releasing" => :pending, "deploying" => :pending }, states(stage), stage)
    end
  end

  test "assembled is Releasing, live, with Building done" do
    assert_equal({ "building" => :done, "releasing" => :live, "deploying" => :pending }, states("assembled"))
    assert_equal({ "building" => :done, "releasing" => :live, "deploying" => :pending },
                 states("assembled", release_stage: "qa_deployed"), "QA is still releasing")
  end

  test "assembled while its release deploys production is Deploying, live" do
    assert_equal({ "building" => :done, "releasing" => :done, "deploying" => :live },
                 states("assembled", release_stage: "prod_deploying"))
  end

  test "shipped shows all three done and nothing live" do
    assert_equal({ "building" => :done, "releasing" => :done, "deploying" => :done }, states("shipped"))
    assert_not AppDevopsStages.from("shipped").any?(&:live?)
  end

  test "an archived or unknown stage shows nothing live" do
    assert_equal({ "building" => :pending, "releasing" => :pending, "deploying" => :pending }, states("archived"))
    assert_equal %w[Building Releasing Deploying], AppDevopsStages.from(nil).map(&:label)
  end

  test "an app reads its build task through the request that claimed its subdomain" do
    own = App.create!(slug: "own-probe", name: "Own Probe", status: "active")
    assert_equal :done, AppDevopsStages.for_app(own).last.state, "no build task: one of our own live apps"

    task = Task.create!(title: "Build Launch App stage-probe", stage: "building", priority: 1)
    AppRequest.create!(prompt: "A probe", subdomain: "stage-probe", task_slug: task.slug)
    app = App.create!(slug: "stage-probe", name: "Stage Probe", status: "active")
    assert_equal %i[live pending pending], AppDevopsStages.for_app(app).map(&:state)

    task.update_columns(stage: "assembled")
    assert_equal %i[done live pending], AppDevopsStages.for_app(app).map(&:state)

    task.update_columns(stage: "archived")
    assert_equal %i[pending pending pending], AppDevopsStages.for_app(app).map(&:state), "archived unshipped"
    task.update_columns(completed_at: Time.current)
    assert_equal %i[done done done], AppDevopsStages.for_app(app).map(&:state), "archive-shipped keeps it done"
  end
end
