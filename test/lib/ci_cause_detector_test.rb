# frozen_string_literal: true

# [unit] CiCauseDetector: a same-SHA red then green is a defect with a cause (Alex
# McRitchie, 2026-11-06). The flips come from run rows; the causes from the red job's
# log, classed infra / harness / test / product. Log text is trimmed from real CI jobs
# (2026-11-01..05; test paths renamed so the citation ratchet does not read them).
require "minitest/autorun"
require_relative "../../bin/lib/ci_cause_detector"

class CiCauseDetectorTest < Minitest::Test
  APT_STALL = <<~LOG
    2026-10-26T14:02:10.0000000Z ##[group]Run .github/scripts/apt-retry curl libvips
    2026-10-26T14:09:10.0000000Z ::warning::apt attempt 3 failed or hung; retrying
    2026-10-26T14:22:10.0000000Z ::error::apt-get failed every attempt
  LOG

  # A green test printed this on purpose; the real failure is the named one.
  DST_FAILURE = <<~LOG
    2026-11-01T13:04:10.0000000Z nflverse seed: FEED UNAVAILABLE — data not refreshed (Errno::ECONNREFUSED: Connection refused)
    2026-11-01T13:04:11.0000000Z Failure:
    2026-11-01T13:04:11.0000001Z ContactFlaggedDigestJobTest#test_[integration]_a_flag_older_than_the_window_does_not_send [test/jobs/sample_digest_job_test.rb:38]:
    2026-11-01T13:04:11.0000002Z 0 emails expected, but 1 were sent.
    2026-11-01T13:04:11.0000003Z
    2026-11-01T13:04:11.0000004Z bin/rails test test/jobs/sample_digest_job_test.rb:33
    2026-11-01T13:04:11.0000005Z
  LOG

  PLAYWRIGHT = <<~LOG
    2026-11-03T10:00:00.0000000Z   1) [chromium] › e2e/sample_race.spec.js:240:3 › recast › results fit a phone
    2026-11-03T10:00:00.0000001Z
    2026-11-03T10:00:00.0000002Z     Error: expect(received).toBeLessThanOrEqual(expected)
    2026-11-03T10:00:00.0000003Z     Expected: <= 390
    2026-11-03T10:00:00.0000004Z     Received:    412
    2026-11-03T10:00:00.0000005Z   2) [chromium] › e2e/sample_race.spec.js:301:3 › recast › swaps a cast member
    2026-11-03T10:00:00.0000006Z
    2026-11-03T10:00:00.0000007Z     Error: Timed out 5000ms waiting for expect(locator).toBeVisible()
  LOG

  PRODUCT_ERROR = <<~LOG
    2026-11-04T09:00:00.0000000Z Error:
    2026-11-04T09:00:00.0000001Z BuildIntakeTest#test_answers_once:
    2026-11-04T09:00:00.0000002Z ActionView::Template::Error: undefined method `name' for nil
    2026-11-04T09:00:00.0000003Z     app/views/builds/_turn.html.erb:12:in `block in render'
    2026-11-04T09:00:00.0000004Z
    2026-11-04T09:00:00.0000005Z bin/rails test test/integration/sample_intake_test.rb:9
  LOG

  SERVER_BOOT = <<~LOG
    2026-11-02T08:00:00.0000000Z Error: Timed out waiting 120000ms from config.webServer.
  LOG

  def test_a_rerun_that_passed_is_a_flip_of_its_failed_attempt
    rows = [
      { run_id: 7, attempt: 1, conclusion: "failure", sha: "abc", workflow: "CI" },
      { run_id: 7, attempt: 2, conclusion: "success", sha: "abc", workflow: "CI" }
    ]
    assert_equal [{ red: { run_id: 7, attempt: 1 }, green: { run_id: 7, attempt: 2 }, sha: "abc", workflow: "CI" }],
                 CiCauseDetector.flips(rows)
  end

  def test_two_runs_at_one_sha_one_red_one_green_is_a_flip
    rows = [
      { "run_id" => 8, "attempt" => 1, "conclusion" => "timed_out", "sha" => "def", "workflow" => "CI" },
      { "run_id" => 9, "attempt" => 1, "conclusion" => "success", "sha" => "def", "workflow" => "CI" }
    ]
    assert_equal [{ run_id: 8, attempt: 1 }], CiCauseDetector.flips(rows).map { |f| f[:red] }
  end

  def test_a_red_with_no_green_a_cancel_or_another_workflow_is_no_flip
    rows = [
      { run_id: 1, attempt: 1, conclusion: "failure", sha: "s", workflow: "CI" },
      { run_id: 2, attempt: 1, conclusion: "success", sha: "s", workflow: "Engine CI" },
      { run_id: 3, attempt: 1, conclusion: "cancelled", sha: "t", workflow: "CI" },
      { run_id: 4, attempt: 1, conclusion: "success", sha: "t", workflow: "CI" }
    ]
    assert_empty CiCauseDetector.flips(rows)
  end

  def test_an_apt_stall_is_infra
    c = only(CiCauseDetector.causes(job_name: "ci / rails (2)", log: APT_STALL))
    assert_equal ["infra", "apt-mirror"], [c[:klass], c[:key]]
    assert(c[:evidence].any? { |l| l.include?("apt-get failed every attempt") })
  end

  def test_a_named_failure_outranks_a_network_word_a_green_test_printed
    c = only(CiCauseDetector.causes(job_name: "ci / rails (1)", log: DST_FAILURE))
    assert_equal ["test", "ContactFlaggedDigestJobTest"], [c[:klass], c[:key]]
    assert_includes c[:evidence], "0 emails expected, but 1 were sent."
  end

  def test_one_spec_file_failing_at_two_lines_is_one_cause
    c = only(CiCauseDetector.causes(job_name: "ci / playwright (3)", log: PLAYWRIGHT))
    assert_equal ["test", "e2e/sample_race.spec.js"], [c[:klass], c[:key]]
  end

  def test_the_app_raising_under_a_test_is_product
    c = only(CiCauseDetector.causes(job_name: "ci / rails (4)", log: PRODUCT_ERROR))
    assert_equal ["product", "BuildIntakeTest"], [c[:klass], c[:key]]
  end

  def test_a_server_that_never_booted_is_harness
    c = only(CiCauseDetector.causes(job_name: "ci / playwright (1)", log: SERVER_BOOT))
    assert_equal ["harness", "web-server-boot"], [c[:klass], c[:key]]
  end

  def test_an_unexplained_red_job_is_harness_keyed_by_job
    c = only(CiCauseDetector.causes(job_name: "ci / static", log: "2026-11-02T08:00:00Z Process completed with exit code 1.\n"))
    assert_equal ["harness", "job:ci / static"], [c[:klass], c[:key]]
  end

  def test_an_executed_set_echo_is_no_cause
    assert_empty CiCauseDetector.causes(job_name: "ci / e2e_executed_set", log: PLAYWRIGHT)
  end

  def test_every_class_is_one_of_the_four
    [APT_STALL, DST_FAILURE, PLAYWRIGHT, PRODUCT_ERROR, SERVER_BOOT].each do |log|
      CiCauseDetector.causes(job_name: "x", log: log).each { |c| assert_includes CiCauseDetector::CLASSES, c[:klass] }
    end
  end

  def test_slug_and_title_are_stable_and_board_shaped
    slug = CiCauseDetector.slug("McRitchie-Studio/mcritchie-studio", "e2e/sample_race.spec.js")
    assert_equal "ci-cause-mcritchie-studio-e2e-sample-race-spec-js", slug
    long = CiCauseDetector.slug("o/r", "SomeVeryLongMinitestClassNameThatGoesOnAndOnForeverAndEverTest")
    assert_operator long.length, :<=, 60
    assert_equal long, CiCauseDetector.slug("o/r", "SomeVeryLongMinitestClassNameThatGoesOnAndOnForeverAndEverTest")
    assert_equal "Find test cause sample_race", CiCauseDetector.title("test", "e2e/sample_race.spec.js")
    assert_equal 4, CiCauseDetector.title("infra", "apt-mirror").split.size
  end

  private

  def only(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end
end
