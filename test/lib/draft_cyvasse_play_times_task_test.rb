require "test_helper"
require "rake"

# [unit] broadcasts:draft_cyvasse_play_times creates the play-times note as a
# draft under a fixed slug, once, and never stages or sends it (task
# cyvasse-play-times-email).
class DraftCyvassePlayTimesTaskTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:draft_cyvasse_play_times")
    @task = Rake::Task["broadcasts:draft_cyvasse_play_times"]
  end

  def run_task
    @task.reenable
    capture_io { @task.invoke }.first
  end

  test "creates one draft on the cyvasse_play_times template, legacy list, and queues no send" do
    out = nil
    assert_no_enqueued_jobs do
      assert_difference -> { Broadcast.count }, 1 do
        out = run_task
      end
    end
    broadcast = Broadcast.find_by!(slug: "cyvasse-play-times")
    assert_equal "cyvasse_play_times", broadcast.template_key
    assert_equal "draft", broadcast.status
    assert_nil broadcast.sent_at
    assert_equal "How was your first game on the new Cyvasse?", broadcast.subject
    assert_equal "cyvasse-legacy", broadcast.target_list
    assert_equal 0, broadcast.deliveries.count
    assert_equal 0, broadcast.staged_emails.count
    assert_match "/broadcasts/cyvasse-play-times/edit", out
  end

  test "a re-run keeps the existing row and its edits" do
    run_task
    Broadcast.find_by!(slug: "cyvasse-play-times").update!(subject: "Edited subject")
    assert_no_difference -> { Broadcast.count } do
      run_task
    end
    assert_equal "Edited subject", Broadcast.find_by!(slug: "cyvasse-play-times").subject
  end
end
