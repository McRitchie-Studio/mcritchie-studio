# frozen_string_literal: true

require "test_helper"

# [unit] BookClose's status vocabulary: the model and the table's CHECK agree,
# so a write that skips validations cannot store a third state.
class BookCloseTest < ActiveSupport::TestCase
  test "status is draft or final, in the model and in the database" do
    assert_equal %w[draft final], BookClose::STATUSES
    refute BookClose.new(entity: "studio", month: "2026-09", status: "done").valid?

    close = BookClose.create!(entity: "studio", month: "2026-09", status: "draft")
    assert_raises(ActiveRecord::StatementInvalid) { close.update_columns(status: "done") }
  end

  test "month is YYYY-MM" do
    refute BookClose.new(entity: "studio", month: "2026-9", status: "draft").valid?
    refute BookClose.new(entity: "studio", month: "2026-13", status: "draft").valid?
  end
end
