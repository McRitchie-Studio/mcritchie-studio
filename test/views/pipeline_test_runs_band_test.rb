require "test_helper"

# [component] the pipeline "Test runs" band partial — each release test-scope
# verdict renders as a gradeable row (scope-key headline, pass/fail pill,
# phase/tier/host DERIVED from the scope registry, counts + duration, a grade
# link to the action drawer); an Alex "not" grade paints the row rail; an empty
# set renders nothing. Rendered in isolation so the band is proven without the
# whole pipeline page.
class PipelineTestRunsBandTest < ActionView::TestCase
  include HeartbeatHelper

  def run_action(scope:, result:, summary: nil, duration_ms: 1200, **attrs)
    AgentAction.create!({
      session_id: "cmp-1", kind: "test_scope", event_slug: scope, result_slug: result,
      summary: summary || "test scope #{scope} #{result == 'pass' ? 'COMPLETED' : 'FAILED'} · host · #{result}",
      duration_ms: duration_ms, occurred_at: Time.current, seq: 0, outcome: "ok", actor: "agent"
    }.merge(attrs))
  end

  def render_band(runs, grades = {})
    render partial: "heartbeat/test_runs_band", locals: { test_runs: runs, test_run_grades: grades }
  end

  test "renders a verdict row with scope key, pass pill, derived meta, counts and grade link" do
    run = run_action(scope: "ship_test_gate", result: "pass", task_slug: "t-x",
                     summary: "test scope ship_test_gate COMPLETED · mcritchie-studio · pass · " \
                              "141 runs, 320 assertions, 0 failures, 0 errors · 12.3s · bin/rails test")
    render_band([run])

    assert_select "[data-test=pl-test-runs]"
    assert_select "[data-test=pl-test-run]" do
      assert_select ".pl-slug", text: "ship_test_gate"
      assert_select "[data-test=pl-test-verdict].good", text: "pass"
      # phase/tier/host DERIVED from the registry (ship_test_gate → ship/full/local)
      assert_select ".pl-tag", text: "ship"
      assert_select ".pl-tag", text: "full"
      assert_select ".pl-tag", text: "local"
      assert_select ".pl-counts", text: /141 runs/
    end
    assert_select "a[href=?]", heartbeat_feedback_path(run.id)
  end

  test "renders the fail pill for a failed verdict" do
    render_band([run_action(scope: "qa_post_deploy", result: "fail")])
    assert_select "[data-test=pl-test-verdict].not", text: "fail"
  end

  test "an Alex 'not' grade paints the row rail" do
    run = run_action(scope: "pre_qa_gate", result: "pass")
    grade = ActionGrade.create!(agent_action: run, grader: "alex", disposition: "not", slug: "flaky gate")
    render_band([run], { run.id => { "alex" => grade } })
    assert_select "[data-test=pl-test-run].is-not", { count: 1 }
  end

  test "renders nothing when there are no verdicts" do
    render_band([])
    assert_select "[data-test=pl-test-runs]", { count: 0 }
  end
end
