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
    assert_equal "Cyvasse is back", broadcast.subject
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
end
