require "test_helper"

# [unit] The /contacts numbers: one contact per state the page counts, on two
# lists, so every tile and breakdown row is pinned to a known answer.
class Contacts::DashboardTest < ActiveSupport::TestCase
  setup do
    @broadcast = Broadcast.create!(slug: "dash-test", subject: "Hello", template_key: "cyvasse_is_back")
    Contact::VERIFICATION_STATUSES.each do |status|
      contact = Contact.create!(email: "#{status}@example.com", tags: %w[cyvasse-legacy])
      contact.record_verification!(status: status, at: Time.zone.parse("2026-09-29 10:00"))
    end
    @fresh = Contact.create!(email: "fresh@example.com", tags: %w[cyvasse-legacy])
    Contact.create!(email: "left@example.com", tags: %w[cyvasse-legacy]).unsubscribe!(reason: "requested")
    Contact.create!(email: "bounce@example.com", tags: %w[cyvasse-legacy]).unsubscribe!(reason: "bounced")
    Contact.create!(email: "other-list@example.com", tags: %w[newsletter])
      .record_verification!(status: "valid", at: Time.zone.parse("2026-09-29 12:00"))
    valid = Contact.find_by!(email: "valid@example.com")
    @broadcast.deliveries.create!(contact: valid, sent_at: 1.hour.ago)
    @broadcast.deliveries.create!(contact: @fresh) # queued, never sent: not "emailed"
  end

  test "the tiles count each state on the default list" do
    stats = Contacts::Dashboard.new.stats

    assert_equal 10, stats.total
    # 4 undeliverable statuses are unsubscribed by the verification, plus 2 who left.
    assert_equal 4, stats.subscribed
    assert_equal 1, stats.valid
    assert_equal 1, stats.mailable
    assert_equal 4, stats.undeliverable
    assert_equal 3, stats.unverified
    assert_equal 1, stats.emailed, "a queued delivery with no sent_at is not an email sent"
    assert_equal Time.zone.parse("2026-09-29 10:00"), stats.last_verified_at
    assert_in_delta 70.0, stats.verified_pct
  end

  test "the breakdown has every status plus unverified, and the reasons" do
    stats = Contacts::Dashboard.new.stats

    assert_equal Contacts::Dashboard::STATUS_ROWS, stats.by_status.keys
    Contact::VERIFICATION_STATUSES.each { |status| assert_equal 1, stats.by_status[status], status }
    assert_equal 3, stats.by_status["unverified"]
    assert_equal({ "requested" => 1, "bounced" => 1, "complained" => 0, "verification" => 4 }, stats.unsubscribed)
  end

  test "all counts every list, and a list nobody carries is empty" do
    all = Contacts::Dashboard.new(list: "all").stats
    assert_equal 11, all.total
    assert_equal 2, all.valid
    assert_equal Time.zone.parse("2026-09-29 12:00"), all.last_verified_at

    none = Contacts::Dashboard.new(list: "no-such-list").stats
    assert_equal 0, none.total
    assert_nil none.last_verified_at
    assert_in_delta 0.0, none.verified_pct
  end

  test "the list picker counts contacts per tag" do
    assert_equal [ [ "cyvasse-legacy", 10 ], [ "newsletter", 1 ] ], Contacts::Dashboard.lists
  end

  test "stats are three queries whatever the list size" do
    queries = count_queries { Contacts::Dashboard.new.stats }
    assert_equal 3, queries
  end

  private

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
