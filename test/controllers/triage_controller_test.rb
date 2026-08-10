require "test_helper"

class TriageControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @finding = TriageFinding.create!(
      title: "Raise hub web concurrency",
      body: "Outage follow-up: hub web dynos run single-process.",
      source: "release-retro", repo: "mcritchie-studio"
    )
  end

  test "[component] index renders open findings for any visitor" do
    get triage_path
    assert_response :success
    assert_match @finding.title, response.body
    assert_match @finding.slug, response.body
  end

  test "[component] promote controls render only for an admin" do
    get triage_path
    refute_match 'value="Promote"', response.body

    log_in_as(@admin)
    get triage_path
    assert_match 'value="Promote"', response.body
  end

  test "[integration] promote mints a designed task and stamps the finding" do
    log_in_as(@admin)
    assert_difference "Task.count", 1 do
      post promote_triage_finding_path(@finding.slug),
           params: { title: "Raise Hub Web Concurrency", kind: "chore" }
    end

    task = Task.order(:created_at).last
    assert_equal "designed", task.stage
    assert_equal "chore", task.metadata.dig("devops", "kind")
    assert_includes task.metadata.dig("devops", "agent_context").to_s, @finding.slug
    assert_equal ["mcritchie-studio"], task.metadata.dig("devops", "repositories")

    @finding.reload
    assert_equal "promoted", @finding.status
    assert_equal task.slug, @finding.promoted_task_slug
  end

  test "[integration] promote surfaces a task validation failure without stamping" do
    log_in_as(@admin)
    assert_no_difference "Task.count" do
      post promote_triage_finding_path(@finding.slug), params: { title: "Too long a task title to pass validation", kind: "chore" }
    end
    assert_equal "open", @finding.reload.status
  end

  test "[integration] promote and dismiss are admin-gated" do
    log_in_as(@viewer)
    post promote_triage_finding_path(@finding.slug), params: { title: "Raise Hub Web Concurrency" }
    assert_equal "open", @finding.reload.status

    post dismiss_triage_finding_path(@finding.slug)
    assert_equal "open", @finding.reload.status
  end

  test "[integration] dismiss retires the finding for an admin" do
    log_in_as(@admin)
    post dismiss_triage_finding_path(@finding.slug)
    assert_equal "dismissed", @finding.reload.status
  end

  test "[integration] promote refuses an already-resolved finding" do
    log_in_as(@admin)
    @finding.dismiss!
    assert_no_difference "Task.count" do
      post promote_triage_finding_path(@finding.slug), params: { title: "Raise Hub Web Concurrency" }
    end
    assert_equal "dismissed", @finding.reload.status
    assert_nil @finding.promoted_task_slug
  end
end
