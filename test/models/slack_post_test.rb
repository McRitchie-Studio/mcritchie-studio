require "test_helper"

# [unit] SlackPost's statuses and kinds match the CHECK constraints its table was
# created with (20261031040000), and which rows are final (never posted again).
class SlackPostTest < ActiveSupport::TestCase
  def check_values(name)
    sql = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = '#{name}'
    SQL
    sql.to_s.scan(/'([a-z_]+)'/).flatten.sort
  end

  test "[unit] the status and kind CHECKs list exactly SlackPost::STATUSES and KINDS" do
    assert_equal SlackPost::STATUSES.sort, check_values("slack_posts_status_known")
    assert_equal SlackPost::KINDS.sort, check_values("slack_posts_kind_known")
  end

  test "[unit] posted, suppressed, sending and ambiguous rows are final; a provable refusal is not" do
    row = ->(status, reason = nil) { SlackPost.new(channel_id: "C1", kind: "post", status: status, reason: reason) }

    assert(%w[posted suppressed sending].all? { |s| row.call(s).final? })
    assert row.call("failed", "#{SlackPost::AMBIGUOUS} timeout").final?
    refute row.call("failed", "not_in_channel: refused").final?
  end

  test "[unit] the medium CHECK lists exactly SlackPost::MEDIA, and a row defaults to slack" do
    assert_equal SlackPost::MEDIA.sort, check_values("slack_posts_medium_known")
    assert_equal "slack", SlackPost.new.medium
    refute SlackPost.new(medium: "discord", channel_id: "C1", kind: "post", status: "posted").valid?
  end
end
