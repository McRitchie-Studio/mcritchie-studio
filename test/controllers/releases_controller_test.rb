require "test_helper"

class ReleasesControllerTest < ActionDispatch::IntegrationTest
  def release_with_member
    release = Release.create!(slug: "rel-controller-metrics", branch: "release", state: "shipped")
    release.update_columns( # rubocop:disable Rails/SkipsModelValidations
      created_at: 60.minutes.ago,
      testing_started_at: 60.minutes.ago, tested_at: 55.minutes.ago,        # Tested    5m
      assembling_started_at: 55.minutes.ago, assembled_at: 30.minutes.ago,  # Assembled 25m
      confirming_started_at: 12.minutes.ago, confirmed_at: 10.minutes.ago,  # Confirmed 2m
      prod_deploy_started_at: 7.minutes.ago, shipped_at: 5.minutes.ago      # Deployed  2m · Total 55m
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

  test "[integration] all deployments renders the per-stage columns, timestamps and durations" do
    release = release_with_member

    get all_deployments_path

    assert_response :success
    assert_select "h2", "All Deployments"
    assert_select "a[href=?]", deployment_path(release), text: release.slug
    # Per-stage columns replace the old Assemble/Confirm/Ship/Deploy set.
    assert_select "table", text: /Tested/
    assert_select "table", text: /Assembled/
    assert_select "table", text: /Confirmed/
    assert_select "table", text: /Deployed/
    assert_select "table", text: /Total/
    assert_select "table thead", text: /Ship/, count: 0
    # Each stage cell carries a timestamp range (start→end) + the duration underneath.
    assert_select "tbody td [data-deployment-range] [data-range-time]"
    assert_select "tbody td", text: /25m/   # Assembled: assembling_started → assembled
    assert_select "tbody td", text: /55m/   # Total: created → shipped
    # Summary cards use the stage labels, not the per-task Building/Reviewing spans.
    assert_match "Tested", response.body
    assert_no_match(/Building/, response.body)
  end

  test "[integration] all deployments paginates releases twenty five per page" do
    base_time = Time.zone.parse("2030-01-01 12:00:00")
    26.times do |index|
      release = Release.create!(slug: "rel-page-#{format('%02d', index + 1)}", branch: "release", state: "shipped")
      release.update_columns( # rubocop:disable Rails/SkipsModelValidations
        created_at: base_time + index.minutes,
        shipped_at: base_time + index.minutes,
        updated_at: base_time + index.minutes
      )
    end

    get all_deployments_path

    assert_response :success
    # 25 release rows + the 2 pinned running-average rows (3-release / 10-release).
    assert_select "tbody tr", count: 27
    assert_select "tbody tr[data-test='deployment-average-row']", count: 2
    assert_includes response.body, "rel-page-26"
    assert_not_includes response.body, "rel-page-01"
    assert_select "a[href=?]", all_deployments_path(page: 2), text: "Next"

    get all_deployments_path(page: 2)

    assert_response :success
    assert_includes response.body, "rel-page-01"
    assert_select "a[href=?]", all_deployments_path(page: 1), text: "Previous"
  end

  test "[integration] release detail renders cached stage and release-step tables" do
    release = release_with_member

    get deployment_path(release)

    assert_response :success
    assert_select "h2", release.slug
    assert_select "section", text: /Member Tasks/
    assert_select "section", text: /Release Steps/
    assert_select "a[href=?]", task_path(release.tasks.first.slug)
  end
end
