require "test_helper"
require "rake"

# [unit] broadcasts:draft_cyvasse_is_back creates the relaunch note as a draft
# under a fixed slug, once, and never sends it.
class DraftCyvasseIsBackTaskTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:draft_cyvasse_is_back")
    @task = Rake::Task["broadcasts:draft_cyvasse_is_back"]
  end

  def run_task
    @task.reenable
    capture_io { @task.invoke }
  end

  test "creates one draft on the cyvasse_is_back template and queues no send" do
    assert_no_enqueued_jobs do
      assert_difference -> { Broadcast.count }, 1 do
        run_task
      end
    end
    broadcast = Broadcast.find_by!(slug: "cyvasse-is-back")
    assert_equal "cyvasse_is_back", broadcast.template_key
    assert_equal "draft", broadcast.status
    assert_equal "\u{1F409} Cyvasse is back \u2014 now with live matches", broadcast.subject
    assert_equal "cyvasse-legacy", broadcast.target_list
  end

  test "a re-run keeps the existing row and its edits" do
    run_task
    Broadcast.find_by!(slug: "cyvasse-is-back").update!(subject: "Edited subject")
    assert_no_difference -> { Broadcast.count } do
      run_task
    end
    assert_equal "Edited subject", Broadcast.find_by!(slug: "cyvasse-is-back").subject
  end

  # [unit] broadcasts:refresh_cyvasse_is_back (the post-deploy of task
  # cyvasse-email-live-copy) moves a draft still on the old subject to the
  # emoji one, and leaves edited, sent or missing rows alone.
  def refresh
    task = Rake::Task["broadcasts:refresh_cyvasse_is_back"]
    task.reenable
    capture_io { task.invoke }.first
  end

  test "refresh moves a draft on the old subject to the new one" do
    Broadcast.create!(slug: "cyvasse-is-back", template_key: "cyvasse_is_back", subject: "Cyvasse is back", status: "draft")
    assert_no_enqueued_jobs { refresh }
    assert_equal "\u{1F409} Cyvasse is back \u2014 now with live matches", Broadcast.find_by!(slug: "cyvasse-is-back").subject
  end

  test "refresh leaves an edited subject and a sent broadcast as they are" do
    edited = Broadcast.create!(slug: "cyvasse-is-back", template_key: "cyvasse_is_back", subject: "Alex's own", status: "draft")
    assert_match "left as it is", refresh
    assert_equal "Alex's own", edited.reload.subject

    edited.update!(subject: "Cyvasse is back", status: "sent", sent_at: 1.hour.ago)
    assert_match "left as it is", refresh
    assert_equal "Cyvasse is back", edited.reload.subject
  end

  test "refresh without the row says so" do
    assert_match "no row", refresh
  end
end

