# frozen_string_literal: true

# [unit] submit waits for late-registering checks (task devops-sub-hour-follow-ups).
#
# GitHub creates a job's check only when the job is queued, so a job that `needs:`
# another (a census after its shards, a shard matrix built from a plan job's output,
# a late Playwright shard) has no check yet while the run is still going. A poll in
# that window saw every existing check pass and called the PR green. CiStatus now
# holds a green rollup at :pending while a push or pull_request run on the head SHA
# is not `completed`. bin/submit's settle wait (bin/lib/ci_wait.rb) waits on :pending,
# so it counts the late checks before it calls green.
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../../bin/lib/ci_status"
require_relative "../../bin/lib/ci_wait"

class CiStatusLateChecksTest < Minitest::Test
  PR = "https://github.com/McRitchie-Studio/turf-monster/pull/77"
  SHA = "0123456789abcdef0123456789abcdef01234567"
  GREEN = { state: :green, count: 9, completed_at: "2026-11-11T05:00:00Z", head_oid: SHA, base_drift: nil }.freeze

  def runs(*rows) = JSON.generate("total_count" => rows.size, "workflow_runs" => rows)

  def run_row(name, status, event: "pull_request", id: 1) = { "id" => id, "name" => name, "status" => status, "event" => event }

  def test_an_unfinished_gating_run_is_named
    raw = runs(run_row("CI", "in_progress"), run_row("UI budget", "queued", event: "schedule", id: 2), run_row("Mirror", "completed", event: "push", id: 3))
    assert_equal ["CI"], CiStatus.unfinished_runs(raw)
  end

  def test_every_run_completed_names_none
    assert_equal [], CiStatus.unfinished_runs(runs(run_row("CI", "completed"), run_row("CI", "completed", event: "push", id: 2)))
  end

  def test_a_failed_read_is_no_answer_not_a_hold
    assert_nil CiStatus.unfinished_runs("gh: HTTP 403: Resource not accessible by integration")
    assert_nil CiStatus.unfinished_runs('{"message":"Not Found"}')
    assert_equal GREEN, CiStatus.late_hold(GREEN, nil)
    assert_equal GREEN, CiStatus.late_hold(GREEN, [])
  end

  def test_a_green_rollup_with_a_run_still_going_is_pending
    v = CiStatus.late_hold(GREEN, ["CI"])
    assert_equal :pending, v[:state]
    assert_equal ["CI"], v[:pending]
    assert_equal SHA, v[:head_oid], "the head SHA still rides along"
    refute v.key?(:count), "a held verdict carries no green count"
    assert_includes v[:reason], "9 check(s) passed"
    assert_equal :wait, CiWait.action_for(v[:state]), "the settle wait keeps waiting on it"
  end

  # The whole read, through a stub gh: the window where every existing check passes
  # and the census job has not been queued yet.
  def test_evaluate_holds_green_until_the_run_completes
    with_gh(run_status: "in_progress") do |calls|
      v = CiStatus.evaluate(PR)
      assert_equal :pending, v[:state], v.inspect
      assert_equal ["CI"], v[:pending]
      assert_includes File.read(calls), "repos/McRitchie-Studio/turf-monster/actions/runs?head_sha=#{SHA}"
    end
    with_gh(run_status: "completed") do
      assert_equal :green, CiStatus.evaluate(PR)[:state]
    end
  end

  def test_evaluate_keeps_the_green_when_the_runs_read_fails
    with_gh(run_status: "refused") do
      assert_equal :green, CiStatus.evaluate(PR)[:state]
    end
  end

  def test_a_red_or_pending_rollup_makes_no_runs_read
    with_gh(run_status: "in_progress", checks: '[{"name":"rails (1)","state":"FAILURE","bucket":"fail"}]') do |calls|
      assert_equal :red, CiStatus.evaluate(PR)[:state]
      refute_includes File.read(calls), "actions/runs"
    end
  end

  private

  def with_gh(run_status:, checks: '[{"name":"ci / static","state":"SUCCESS","bucket":"pass"}]')
    Dir.mktmpdir do |dir|
      calls = File.join(dir, "calls")
      File.write(calls, "")
      view = JSON.generate("state" => "OPEN", "mergeStateStatus" => "CLEAN", "mergeable" => "MERGEABLE",
                           "baseRefName" => "accepted", "headRefOid" => SHA)
      runs_body = run_status == "refused" ? nil : runs(run_row("CI", run_status))
      gh = File.join(dir, "gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        echo "$*" >> "#{calls}"
        case "$1 $2" in
          "pr view") printf '%s' '#{view}' ;;
          "pr checks") printf '%s' '#{checks}' ;;
          *) #{runs_body ? "printf '%s' '#{runs_body}'" : "echo 'gh: HTTP 403' >&2; exit 1"} ;;
        esac
      SH
      File.chmod(0o755, gh)
      with_env("CI_STATUS_GH_BIN" => gh, "GH_TOKEN" => "stub-token", "GH_AUTH_TOKEN_BIN" => "/usr/bin/false") do
        CiStatus.reset_gh_auth!
        begin
          yield calls
        ensure
          CiStatus.reset_gh_auth!
        end
      end
    end
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
