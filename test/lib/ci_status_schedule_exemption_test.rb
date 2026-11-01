# frozen_string_literal: true

# [unit] + [integration] CiStatus's schedule exemption. The SHA verdict leaves out a check-run
# it can PROVE was triggered by a `schedule` event, by joining check_suite.id to the SHA's
# workflow runs, and keeps every run it cannot prove. A red nightly UI Budget run cannot block
# a ship; a red push run still does.
# History: task ui-budget-report-never-gates.
require "minitest/autorun"
require "json"
require_relative "../../bin/lib/ci_status"

class CiStatusScheduleExemptionTest < Minitest::Test
  SHA = "e966c75aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  SCHEDULE_SUITE = 9001
  PUSH_SUITE = 9002

  def run_on(name, conclusion, suite, sha: SHA)
    { "name" => name, "status" => "completed", "conclusion" => conclusion,
      "head_sha" => sha, "check_suite" => { "id" => suite } }
  end

  def workflow(event, suite, sha: SHA, name: "wf")
    { "id" => suite + 1, "name" => name, "event" => event, "head_sha" => sha, "check_suite_id" => suite }
  end

  def payload(runs, workflow_runs = nil)
    envelope = { "total_count" => runs.size, "check_runs" => runs }
    envelope["workflow_runs"] = workflow_runs unless workflow_runs.nil?
    JSON.generate(envelope)
  end

  def red_schedule_beside_green_push
    payload([run_on("budget", "failure", SCHEDULE_SUITE), run_on("test", "success", PUSH_SUITE)],
            [workflow("schedule", SCHEDULE_SUITE, name: "UI Budget"), workflow("push", PUSH_SUITE, name: "CI")])
  end

  # ---- [integration] for_sha through the RELEASE_CI_STATUS seam ----

  def test_a_red_schedule_run_beside_a_green_push_run_is_green
    v = CiStatus.for_sha("o/r", SHA, red_schedule_beside_green_push)
    assert_equal :green, v[:state], v.inspect
    assert_equal 1, v[:count], "only the push run judged the SHA"
    assert_equal ["budget"], v[:ignored], "the verdict names the run it did not count"
  end

  def test_a_red_push_run_is_still_red
    v = CiStatus.for_sha("o/r", SHA, payload(
      [run_on("budget", "success", SCHEDULE_SUITE), run_on("test", "failure", PUSH_SUITE)],
      [workflow("schedule", SCHEDULE_SUITE), workflow("push", PUSH_SUITE)]
    ))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_a_red_push_run_beside_a_red_schedule_run_is_red_naming_only_the_push_run
    v = CiStatus.for_sha("o/r", SHA, payload(
      [run_on("budget", "failure", SCHEDULE_SUITE), run_on("test", "failure", PUSH_SUITE)],
      [workflow("schedule", SCHEDULE_SUITE), workflow("push", PUSH_SUITE)]
    ))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_only_a_schedule_run_on_the_sha_is_no_data_not_green
    # A nightly does not certify a commit: with nothing else on the SHA there is no verdict.
    v = CiStatus.for_sha("o/r", SHA, payload([run_on("budget", "success", SCHEDULE_SUITE)],
                                             [workflow("schedule", SCHEDULE_SUITE)]))
    assert_equal :none, v[:state]
  end

  # ---- fail closed: no proof, no exemption ----

  def test_no_workflow_runs_in_the_record_exempts_nothing
    v = CiStatus.for_sha("o/r", SHA, payload([run_on("budget", "failure", SCHEDULE_SUITE),
                                              run_on("test", "success", PUSH_SUITE)]))
    assert_equal :red, v[:state], "without the workflow-runs read nothing is proven"
    refute v.key?(:ignored)
  end

  def test_a_check_run_with_no_suite_id_is_kept
    run = run_on("budget", "failure", SCHEDULE_SUITE).tap { |r| r.delete("check_suite") }
    v = CiStatus.for_sha("o/r", SHA, payload([run], [workflow("schedule", SCHEDULE_SUITE)]))
    assert_equal :red, v[:state]
  end

  def test_a_suite_with_no_matching_workflow_run_is_kept
    v = CiStatus.for_sha("o/r", SHA, payload([run_on("budget", "failure", SCHEDULE_SUITE)],
                                             [workflow("schedule", 4242)]))
    assert_equal :red, v[:state]
  end

  def test_a_suite_whose_workflow_runs_disagree_on_the_event_is_kept
    v = CiStatus.for_sha("o/r", SHA, payload([run_on("budget", "failure", SCHEDULE_SUITE)],
                                             [workflow("schedule", SCHEDULE_SUITE), workflow("push", SCHEDULE_SUITE)]))
    assert_equal :red, v[:state]
  end

  def test_only_the_exact_event_schedule_is_exempt
    %w[push workflow_dispatch pull_request Schedule scheduled].push(nil).each do |event|
      v = CiStatus.for_sha("o/r", SHA, payload([run_on("budget", "failure", SCHEDULE_SUITE)],
                                               [workflow(event, SCHEDULE_SUITE)]))
      assert_equal :red, v[:state], "event #{event.inspect} must not be exempt"
    end
  end

  def test_a_sha_mismatch_on_either_side_is_kept
    other = "b" * 40
    on_run = payload([run_on("budget", "failure", SCHEDULE_SUITE, sha: other)], [workflow("schedule", SCHEDULE_SUITE)])
    on_workflow = payload([run_on("budget", "failure", SCHEDULE_SUITE)], [workflow("schedule", SCHEDULE_SUITE, sha: other)])
    [on_run, on_workflow].each { |raw| assert_equal :red, CiStatus.for_sha("o/r", SHA, raw)[:state] }
  end

  def test_no_sha_exempts_nothing
    assert_equal :red, CiStatus.parse_check_runs(red_schedule_beside_green_push)[:state]
    assert_equal :red, CiStatus.for_sha("o/r", "", red_schedule_beside_green_push)[:state]
  end

  def test_no_sha_anywhere_is_not_an_agreement
    # A blank SHA on the query, the run AND the workflow run must not "match".
    raw = payload([run_on("budget", "failure", SCHEDULE_SUITE, sha: "")], [workflow("schedule", SCHEDULE_SUITE, sha: "")])
    assert_equal :red, CiStatus.parse_check_runs(raw, sha: "")[:state]
    assert_equal :red, CiStatus.parse_check_runs(raw, sha: nil)[:state]
  end

  def test_a_string_suite_id_is_not_a_match
    run = run_on("budget", "failure", SCHEDULE_SUITE).merge("check_suite" => { "id" => SCHEDULE_SUITE.to_s })
    v = CiStatus.for_sha("o/r", SHA, payload([run], [workflow("schedule", SCHEDULE_SUITE)]))
    assert_equal :red, v[:state]
  end

  def test_a_truncated_record_still_reports_itself
    raw = JSON.generate("total_count" => 3,
                        "check_runs" => [run_on("budget", "failure", SCHEDULE_SUITE), run_on("test", "success", PUSH_SUITE)],
                        "workflow_runs" => [workflow("schedule", SCHEDULE_SUITE), workflow("push", PUSH_SUITE)])
    assert_equal :unverified, CiStatus.for_sha("o/r", SHA, raw)[:state],
                 "exempting the red run must not turn a partial read into a green"
  end

  # ---- the G3 credit judges the same set ----

  def test_the_credit_ignores_a_red_schedule_run_too
    raw = payload([run_on("budget", "failure", SCHEDULE_SUITE), run_on("test", "success", PUSH_SUITE),
                   { "name" => "test", "status" => "queued", "conclusion" => nil, "head_sha" => SHA,
                     "check_suite" => { "id" => 9003 } }],
                  [workflow("schedule", SCHEDULE_SUITE), workflow("push", PUSH_SUITE), workflow("push", 9003)])
    v = CiStatus.credit_for_sha("o/r", SHA, raw)
    assert v, "the duplicate pending push run is credited past the schedule red"
    assert_equal :green, v[:state]
    assert_nil CiStatus.credited_verdict(raw), "without a SHA the red schedule run still refuses credit"
  end

  # ---- [unit] the live read joins the two records, and fails closed ----

  def with_gh(check_runs_body, workflow_body, workflow_ok: true)
    calls = []
    CiStatus.singleton_class.alias_method(:__orig_gh_read_status, :gh_read_status)
    CiStatus.define_singleton_method(:gh_read_status) do |*args|
      calls << args
      args[1].include?("/actions/runs") ? [workflow_body, workflow_ok] : [check_runs_body, true]
    end
    yield calls
  ensure
    CiStatus.singleton_class.alias_method(:gh_read_status, :__orig_gh_read_status)
    CiStatus.singleton_class.send(:remove_method, :__orig_gh_read_status)
  end

  def live_check_runs
    JSON.generate("total_count" => 2,
                  "check_runs" => [run_on("budget", "failure", SCHEDULE_SUITE), run_on("test", "success", PUSH_SUITE)])
  end

  def live_workflow_runs
    JSON.generate("total_count" => 2,
                  "workflow_runs" => [workflow("schedule", SCHEDULE_SUITE), workflow("push", PUSH_SUITE)])
  end

  def test_the_live_read_asks_for_the_shas_workflow_runs_and_exempts_the_schedule_run
    with_gh(live_check_runs, live_workflow_runs) do |calls|
      v = CiStatus.for_sha("o/r", SHA, nil)
      assert_equal :green, v[:state], v.inspect
      assert_equal ["budget"], v[:ignored]
      assert_includes calls.map { |c| c[1] }, "repos/o/r/actions/runs?head_sha=#{SHA}&per_page=100"
    end
  end

  def test_a_refused_workflow_runs_read_fails_closed_to_red
    with_gh(live_check_runs, '{"message":"Resource not accessible by integration","status":"403"}', workflow_ok: false) do
      assert_equal :red, CiStatus.for_sha("o/r", SHA, nil)[:state]
    end
  end

  def test_an_unparseable_workflow_runs_body_fails_closed_to_red
    with_gh(live_check_runs, "not json") do
      assert_equal :red, CiStatus.for_sha("o/r", SHA, nil)[:state]
    end
  end

  def test_an_unreadable_check_runs_body_is_classified_as_before
    with_gh('{"message":"Bad credentials","status":"401"}', live_workflow_runs) do |calls|
      v = CiStatus.for_sha("o/r", SHA, nil)
      assert_equal :unreadable, v[:state]
      refute(calls.any? { |c| c[1].include?("/actions/runs") }, "no second read when the first cannot be parsed")
    end
  end
end
