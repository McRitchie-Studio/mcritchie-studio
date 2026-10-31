require "test_helper"
require "rake"

# [unit] broadcasts:draft_cyvasse_four_styles makes the four drafts once and
# broadcasts:stage_cyvasse_four refuses without a LIMIT; neither sends (task
# cyvasse-four-prong-emails).
class CyvasseFourTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SLUGS = %w[cyvasse-four-poster cyvasse-four-pick cyvasse-four-wrapped cyvasse-four-dragon].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:draft_cyvasse_four_styles")
    @draft = Rake::Task["broadcasts:draft_cyvasse_four_styles"]
    @stage = Rake::Task["broadcasts:stage_cyvasse_four"]
  end

  def run_draft
    @draft.reenable
    capture_io { @draft.invoke }.first
  end

  test "creates four drafts on the legacy list and queues no send" do
    out = nil
    assert_no_enqueued_jobs do
      assert_difference -> { Broadcast.count }, 4 do
        out = run_draft
      end
    end
    Broadcast.where(slug: SLUGS).each do |b|
      assert_equal "draft", b.status
      assert_equal "cyvasse-legacy", b.target_list
      assert_empty b.required_merge_fields, b.slug
      assert b.requires_staging?, "#{b.slug} must go out through the queue"
      assert_raises(ArgumentError) { b.send_batch!(size: 1) }
      assert_equal "broadcast_email_bare", b.email_layout
    end
    SLUGS.each { |s| assert_match "/broadcasts/#{s}/edit", out }
  end

  test "a re-run keeps the rows and their edits" do
    run_draft
    Broadcast.find_by!(slug: "cyvasse-four-dragon").update!(subject: "Edited")
    assert_no_difference -> { Broadcast.count } do
      run_draft
    end
    assert_equal "Edited", Broadcast.find_by!(slug: "cyvasse-four-dragon").subject
  end

  test "staging without a LIMIT stops" do
    @stage.reenable
    assert_raises(SystemExit) { capture_io { @stage.invoke } }
  end
end
