require "test_helper"

# [unit] DeskCaptureItem — the allowlist (the capture door's one security
# property) and the row contract the poller and sweep share.
class DeskCaptureItemTest < ActiveSupport::TestCase
  test "allowlist reads env, case-insensitively, and refuses strangers" do
    original = ENV["DESK_ALLOWED_SENDERS"]
    ENV["DESK_ALLOWED_SENDERS"] = "Me@Example.com, other@example.com"

    assert DeskCaptureItem.allowlisted?("me@example.com")
    assert DeskCaptureItem.allowlisted?(" OTHER@EXAMPLE.COM ")
    refute DeskCaptureItem.allowlisted?("broker@clearlyacquired.com"),
      "an unknown sender must quarantine — the desk address is guessable"
    refute DeskCaptureItem.allowlisted?(nil)
  ensure
    original ? ENV["DESK_ALLOWED_SENDERS"] = original : ENV.delete("DESK_ALLOWED_SENDERS")
  end

  test "s3_key is required and unique; status constrained" do
    item = DeskCaptureItem.create!(s3_key: "incoming/abc", status: "received")
    assert item.persisted?

    dup = DeskCaptureItem.new(s3_key: "incoming/abc")
    refute dup.valid?, "one row per S3 object, ever — the poller's idempotency anchor"

    assert_raises(ActiveRecord::RecordInvalid) do
      DeskCaptureItem.create!(s3_key: "incoming/def", status: "pending")
    end
  end

  test "awaiting_sweep is received-only, oldest first" do
    old = DeskCaptureItem.create!(s3_key: "incoming/1", status: "received", received_at: 2.hours.ago)
    DeskCaptureItem.create!(s3_key: "incoming/2", status: "quarantined", received_at: 1.hour.ago)
    newer = DeskCaptureItem.create!(s3_key: "incoming/3", status: "received", received_at: 1.minute.ago)

    assert_equal [old, newer], DeskCaptureItem.awaiting_sweep.to_a
  end
end
