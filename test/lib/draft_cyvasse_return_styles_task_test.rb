require "test_helper"
require "rake"

# [unit] broadcasts:draft_cyvasse_return_styles creates the three return
# emails as drafts, once, and never stages or sends them (task
# cyvasse-three-return-emails).
class DraftCyvasseReturnStylesTaskTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SLUGS = %w[cyvasse-return-record cyvasse-return-challenge cyvasse-return-founder].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:draft_cyvasse_return_styles")
    @task = Rake::Task["broadcasts:draft_cyvasse_return_styles"]
  end

  def run_task
    @task.reenable
    capture_io { @task.invoke }.first
  end

  test "creates three drafts on the legacy list with plain subjects and queues no send" do
    out = nil
    assert_no_enqueued_jobs do
      assert_difference -> { Broadcast.count }, 3 do
        out = run_task
      end
    end
    rows = Broadcast.where(slug: SLUGS).index_by(&:slug)
    assert_equal %w[cyvasse_record cyvasse_challenge cyvasse_founder_note], SLUGS.map { |s| rows[s].template_key }
    rows.each_value do |b|
      assert_equal "draft", b.status
      assert_equal "cyvasse-legacy", b.target_list
      assert_not b.requires_staging?, "#{b.slug} must not require a merge field"
      assert_equal 0, b.deliveries.count + b.staged_emails.count
    end
    assert_equal "I rebuilt Cyvasse", rows["cyvasse-return-founder"].subject
    SLUGS.each { |s| assert_match "/broadcasts/#{s}/edit", out }
  end

  test "a re-run keeps the existing rows and their edits" do
    run_task
    Broadcast.find_by!(slug: "cyvasse-return-challenge").update!(subject: "Edited")
    assert_no_difference -> { Broadcast.count } do
      run_task
    end
    assert_equal "Edited", Broadcast.find_by!(slug: "cyvasse-return-challenge").subject
  end
end
