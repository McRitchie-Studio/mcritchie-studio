require "test_helper"

# [integration] The live GitHub Actions panel on /deployments — the latest run per
# workflow, each row status-pilled (running / passed / failed) and linked to its
# GitHub run, with a quiet empty state when no runs exist yet.
class DeploymentsGithubActionsTest < ActionDispatch::IntegrationTest
  setup { GithubWorkflowRun.delete_all }

  test "[integration] panel renders all six distinct states with GitHub links" do
    # One distinct workflow_name per state, so latest_per_workflow shows all six at
    # once — the full palette the operator compares before we submit.
    queued   = make_run(workflow: "Lint", run_id: 100, status: "queued",
                        sha: "aaaaaaa000000000000000000000000000000000", branch: "feat/webhook-push-not-poll",
                        url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/100")
    running  = make_run(workflow: "CI", run_id: 101, status: "in_progress",
                        sha: "abcdef1234567890abcdef1234567890abcdef12", branch: "feat/webhook-push-not-poll",
                        url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/101")
    passed   = make_run(workflow: "QA Deploy", run_id: 102, status: "completed", conclusion: "success",
                        branch: "release", url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/102")
    failed   = make_run(workflow: "Production Deploy", run_id: 103, status: "completed", conclusion: "failure",
                        branch: "main", url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/103")
    cancel   = make_run(workflow: "Nightly", run_id: 104, status: "completed", conclusion: "cancelled",
                        branch: "main", url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/104")
    timedout = make_run(workflow: "Security", run_id: 105, status: "completed", conclusion: "timed_out",
                        branch: "main", url: "https://github.com/mcritchie/mcritchie-studio/actions/runs/105")

    get deployments_path
    assert_response :success

    assert_select "#github-actions-panel", 1
    assert_select "[data-test='github-actions-run']", 6

    # Each state is visually distinct: its own data-state, label, and pill colour.
    # queued is static (dashed, NOT pulsing); running pulses; the rest are terminal.
    assert_run_row(queued,   state: "queued",    label: "queued",    pill_color: "amber",  pulses: false)
    assert_run_row(running,  state: "running",   label: "running",   pill_color: "amber",  pulses: true)
    assert_run_row(passed,   state: "passed",    label: "passed",    pill_color: "green")
    assert_run_row(failed,   state: "failed",    label: "failed",    pill_color: "red")
    assert_run_row(cancel,   state: "cancelled", label: "cancelled", pill_color: "gray")
    assert_run_row(timedout, state: "timed_out", label: "timed out", pill_color: "orange")

    # queued must NOT pulse (distinct from running) — its pill is dashed + hollow.
    queued_pill = css_select("[data-workflow='Lint'] [data-test='github-actions-pill']").first["class"]
    assert_not_includes queued_pill, "animate-pulse", "queued must be static, not pulsing"
    assert_includes queued_pill, "border-dashed", "queued pill is dashed/hollow"

    # Short SHA (7 chars) is shown, not the full 40.
    assert_select "[data-test='github-actions-run'] code", text: "abcdef1"
    assert_select "[data-test='github-actions-run']", text: /feat\/webhook-push-not-poll/
  end

  test "[integration] shows only the most recent run per workflow" do
    make_run(workflow: "CI", run_id: 201, status: "completed", conclusion: "failure",
             url: "https://example.com/old", run_started_at: 2.hours.ago)
    make_run(workflow: "CI", run_id: 202, status: "in_progress",
             url: "https://example.com/new", run_started_at: 2.minutes.ago)

    get deployments_path
    assert_response :success

    assert_select "[data-test='github-actions-run'][data-workflow='CI']", 1
    assert_select "[data-test='github-actions-run'][data-state='running']", 1
    assert_select "a[href=?]", "https://example.com/new"
    assert_select "a[href=?]", "https://example.com/old", count: 0
  end

  test "[integration] quiet empty state when there are no runs" do
    get deployments_path
    assert_response :success

    assert_select "#github-actions-panel", 1
    assert_select "[data-test='github-actions-run']", 0
    assert_select "[data-test='github-actions-empty']", text: "No Actions runs yet"
  end

  private

  def make_run(workflow:, run_id:, status:, url:, conclusion: nil, sha: "0" * 40,
               branch: "main", run_started_at: Time.current)
    GithubWorkflowRun.create!(
      repo: "mcritchie/mcritchie-studio", workflow_name: workflow, run_id: run_id,
      status: status, conclusion: conclusion, head_sha: sha, head_branch: branch,
      html_url: url, run_started_at: run_started_at
    )
  end

  def assert_run_row(run, state:, label:, pill_color:, pulses: false)
    selector = "[data-test='github-actions-run'][data-workflow='#{run.workflow_name}']"
    assert_select "a#{selector}[href=?][data-state=?]", run.html_url, state
    assert_select "#{selector} [data-test='github-actions-pill']", text: label do |pills|
      classes = pills.first["class"]
      assert_includes classes, pill_color, "#{state} pill should be #{pill_color}"
      assert_includes(classes, "animate-pulse", "running pill should pulse") if pulses
    end
  end
end
