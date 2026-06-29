require "test_helper"

class ReleasesControllerTest < ActionDispatch::IntegrationTest
  def release_with_member
    release = Release.create!(slug: "rel-controller-metrics", branch: "release", state: "shipped")
    release.update_columns( # rubocop:disable Rails/SkipsModelValidations
      created_at: 1.hour.ago,
      assembled_at: 30.minutes.ago,
      confirmed_at: 10.minutes.ago,
      shipped_at: 5.minutes.ago
    )
    task = Task.create!(title: "controller release member task", stage: "shipped", release_slug: release.slug)
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, kind: "intent", from_stage: "designed", to_stage: "building",
                      occurred_at: 50.minutes.ago, actor: "builder")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 40.minutes.ago, seconds_in_from: 10.minutes.to_i,
                      actor: "builder", source: "cli", model: "gpt-5",
                      tokens_in: 1000, tokens_out: 250, cost: "0.0500")
    Release::DurationCache.refresh!(release)
    release.reload
  end

  test "[integration] all deployments renders releases table and cached averages" do
    release = release_with_member

    get all_deployments_path

    assert_response :success
    assert_select "h2", "All Deployments"
    assert_select "a[href=?]", deployment_path(release), text: release.slug
    assert_select "table", text: /Assemble/
    assert_select "table", text: /Confirm/
    assert_select "table", text: /Ship/
    assert_select "table", text: /Deploy/
    assert_select "tbody td", text: "30m"
    assert_select "tbody td", text: "20m"
    assert_select "tbody td", text: "5m"
    assert_select "tbody td", text: "55m"
    assert_match "Building", response.body
  end

  test "[integration] release detail renders cached stage and event tables" do
    release = release_with_member

    get deployment_path(release)

    assert_response :success
    assert_select "h2", release.slug
    assert_select "section", text: /Member Tasks/
    assert_select "section", text: /Release Events/
    assert_select "a[href=?]", task_path(release.tasks.first.slug)
  end
end
