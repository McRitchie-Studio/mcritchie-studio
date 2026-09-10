require "test_helper"

# [unit] THE SETTLE AT `reviewed` LEAVES AN ADDRESSED RECORD (surface-waiting-request-at-merge).
#
# Mr. McRitchie's decision, 2026-09-10: SURFACE IT, DO NOT BLOCK. Review may merge a
# task whose operator-approval request is still `waiting`; nothing refuses. But the
# merge must not swallow the question. Before this, the move to `reviewed` settled the
# request to `none` in silence, and `approval_requested_by` was a field no writer ever
# filled — so even a reader who went looking could not tell who had asked.
#
# What this file pins:
#   1. opening a request stamps WHO asked (a soul actor, else the recorded builder);
#   2. the settle posts ONE comment on the task, addressed to that setter, naming
#      when and for which page, and how the operator can still answer;
#   3. the merger is never mistaken for the setter;
#   4. a note that fails to post never rolls back or refuses the move.
# The end-to-end half, through the real PATCHes, is
# test/integration/ship_preserves_approval_request_test.rb.
class TaskUnansweredApprovalRecordTest < ActiveSupport::TestCase
  LOCAL_URL = "http://localhost:3015/tasks/demo".freeze

  setup { Current.reset }
  teardown { Current.reset }

  def built_task(built_by: "steffon")
    Task.create!(title: "Unanswered Approval Row", stage: "building",
                 metadata: { "devops" => { "kind" => "feature", "built_by" => built_by } })
  end

  def request_approval!(task)
    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "waiting",
                                                                  "local_url" => LOCAL_URL }))
  end

  def unanswered_notes(task)
    Activity.for_task(task).where("metadata->>'kind' = ?", "approval_request_unanswered")
  end

  test "[unit] opening a request stamps the recorded builder as the setter" do
    task = built_task
    request_approval!(task)

    assert_equal "steffon", task.reload.devops["approval_requested_by"],
                 "bin/task update sends no actor, so the builder is who asked"
    assert task.devops["approval_requested_at"].present?
  end

  test "[unit] an explicit soul actor on the write outranks the builder" do
    task = built_task
    Current.task_event_actor = "shannon"
    request_approval!(task)

    assert_equal "shannon", task.reload.devops["approval_requested_by"]
  end

  test "[unit] an actor that is not a soul is not stamped as the setter" do
    task = built_task
    Current.task_event_actor = "2f6c1f0e-session-uuid"
    request_approval!(task)

    assert_equal "steffon", task.reload.devops["approval_requested_by"],
                 "a session id names nobody a note could be addressed to"
  end

  test "[unit] the settle at reviewed posts one note addressed to the setter" do
    task = built_task
    request_approval!(task)
    requested_at = task.reload.devops["approval_requested_at"]
    task.update!(stage: "submitted")
    assert_empty unanswered_notes(task), "nothing settles inside the window"

    task.update!(stage: "reviewed")

    notes = unanswered_notes(task).to_a
    assert_equal 1, notes.size, "exactly one record per settle"
    note = notes.first
    assert_equal "comment", note.activity_type, "a plain comment: it gates nothing"
    assert_equal "steffon", note.metadata["addressed_to"]
    assert_equal "steffon", note.metadata["requested_by"]
    assert_equal requested_at, note.metadata["requested_at"]
    assert_equal LOCAL_URL, note.metadata["local_url"]
    assert_equal "reviewed", note.metadata["stage"]
    assert note.description.start_with?("To steffon:"), "addressed to the setter, first word"
    assert_includes note.description, "UNANSWERED"
    assert_includes note.description, "bin/task update #{task.slug} --approval approved"
    assert_equal "none", task.reload.approval_status, "the settle itself is unchanged"
  end

  test "[unit] the merger is never recorded as the setter, even on an unstamped request" do
    # A request opened BEFORE setters were stamped carries no approval_requested_by,
    # so the settle has to fall back. It may fall back to the builder, never to the
    # actor on the merge write: that is whoever MERGED, not whoever asked.
    task = built_task
    request_approval!(task)
    task.update!(stage: "submitted")
    legacy = task.reload.metadata.deep_dup
    legacy["devops"].delete("approval_requested_by")
    task.update_column(:metadata, legacy) # rubocop:disable Rails/SkipsModelValidations

    Current.task_event_actor = "carl"
    task.reload.update!(stage: "reviewed")

    note = unanswered_notes(task).first
    assert_equal "steffon", note.metadata["addressed_to"]
  end

  test "[unit] a later save posts no second note" do
    task = built_task
    request_approval!(task)
    task.update!(stage: "submitted")
    task.update!(stage: "reviewed")

    task.update!(title: "Unanswered Approval Row Two")
    task.reload.update!(stage: "assembled")

    assert_equal 1, unanswered_notes(task).count
  end

  test "[unit] a merge with no waiting request posts nothing" do
    task = built_task
    task.update!(stage: "submitted")
    task.update!(stage: "reviewed")

    assert_empty unanswered_notes(task)
  end

  test "[unit] an answered request is not reported as unanswered" do
    task = built_task
    request_approval!(task)
    task.update!(metadata: task.reload.metadata.deep_merge("devops" => { "approval_status" => "approved" }))
    task.update!(stage: "submitted")
    task.update!(stage: "reviewed")

    assert_empty unanswered_notes(task)
    assert_equal "approved", task.reload.approval_status
  end

  test "[unit] a note that fails to post never refuses or rolls back the move" do
    task = built_task
    request_approval!(task)
    task.update!(stage: "submitted")

    Activity.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_nothing_raised { task.update!(stage: "reviewed") }
    end

    task.reload
    assert_equal "reviewed", task.stage, "the move landed"
    assert_equal "none", task.approval_status
    assert ErrorLog.where(target_name: task.slug).exists?, "and the failure is on the record"
  end
end
