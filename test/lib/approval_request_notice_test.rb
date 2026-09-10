# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/lib/approval_request_notice"

# [unit] The merge-time block for a carried operator-approval request
# (surface-waiting-request-at-merge). bin/task show, bin/pr-review and
# bin/review-autopilot all print it; this pins what a reviewer reads before merging.
class ApprovalRequestNoticeTest < Minitest::Test
  WAITING_DEVOPS = {
    "approval_status" => "waiting",
    "approval_requested_by" => "steffon",
    "approval_requested_at" => "2026-09-10T14:00:00Z",
    "local_url" => "http://localhost:3015/tasks/demo"
  }.freeze

  def api_task(devops) = { "slug" => "demo-task", "metadata" => { "devops" => devops } }

  def test_prints_nothing_unless_the_request_is_waiting
    %w[none approved changes_requested].each do |status|
      assert_empty ApprovalRequestNotice.lines(api_task(WAITING_DEVOPS.merge("approval_status" => status))),
                   "#{status} is answered or absent, so there is nothing to surface"
    end
    assert_empty ApprovalRequestNotice.lines(nil)
    assert_empty ApprovalRequestNotice.lines({})
  end

  def test_names_who_asked_when_the_page_and_the_note
    text = ApprovalRequestNotice.lines(api_task(WAITING_DEVOPS), note: "Look at the new\n  chip copy.").join("\n")

    assert_includes text, "OPERATOR APPROVAL STILL WAITING"
    assert_includes text, "information, not a gate", "the block must say it refuses nothing"
    assert_includes text, "asked by: steffon"
    assert_includes text, "at: 2026-09-10T14:00:00Z"
    assert_includes text, "local demo: http://localhost:3015/tasks/demo"
    assert_includes text, "the note that asked: Look at the new chip copy.", "whitespace is flattened"
    assert_includes text, "bin/task update demo-task --approval approved"
  end

  def test_reads_the_flattened_shape_bin_pr_review_passes
    flat = { "slug" => "demo-task", "devops" => WAITING_DEVOPS }

    assert ApprovalRequestNotice.waiting?(flat)
    assert_includes ApprovalRequestNotice.lines(flat).join("\n"), "asked by: steffon"
  end

  def test_says_so_when_a_fact_is_missing_rather_than_printing_blank
    text = ApprovalRequestNotice.lines(api_task("approval_status" => "waiting")).join("\n")

    assert_includes text, "asked by: unknown (no setter on record)"
    assert_includes text, "at: unrecorded"
    assert_includes text, "local demo: none recorded"
    assert_includes text, "the note that asked: no handoff note on record"
  end

  def test_a_long_note_is_truncated
    line = ApprovalRequestNotice.lines(api_task(WAITING_DEVOPS), note: "x" * 1000)
                                .find { |l| l.include?("the note that asked") }

    assert_operator line.length, :<, ApprovalRequestNotice::NOTE_LIMIT + 40
    assert line.end_with?("..."), "a cut note says it was cut"
  end
end
