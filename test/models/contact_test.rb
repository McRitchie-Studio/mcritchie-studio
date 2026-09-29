require "test_helper"

# [unit] Leaving and rejoining the list.
class ContactTest < ActiveSupport::TestCase
  setup { @contact = Contact.create!(email: "c-#{SecureRandom.hex(3)}@example.com") }

  test "resubscribe clears the unsubscribe and its reason" do
    @contact.unsubscribe!(reason: "requested")
    @contact.resubscribe!
    @contact.reload
    assert @contact.subscribed?
    assert_nil @contact.unsubscribed_at
    assert_nil @contact.unsubscribe_reason
  end

  test "after resubscribing, unsubscribing works again with a fresh reason" do
    @contact.unsubscribe!(reason: "requested")
    @contact.resubscribe!
    @contact.unsubscribe!(reason: "complained")
    assert_equal "complained", @contact.reload.unsubscribe_reason
  end

  test "record_verification stores the verdict and keeps a valid address subscribed" do
    @contact.record_verification!(status: "Valid", sub_status: "alias_address")
    @contact.reload
    assert_equal "valid", @contact.verification_status
    assert_equal "alias_address", @contact.verification_sub_status
    assert_not_nil @contact.verified_at
    assert @contact.subscribed?
    assert_not @contact.undeliverable?
  end

  test "invalid, spamtrap, abuse and do_not_mail unsubscribe with reason verification" do
    Contact::UNDELIVERABLE_STATUSES.each do |status|
      contact = Contact.create!(email: "#{status}-#{SecureRandom.hex(3)}@example.com")
      contact.record_verification!(status: status)
      contact.reload
      assert_not contact.subscribed?, status
      assert_equal "verification", contact.unsubscribe_reason, status
      assert contact.undeliverable?, status
    end
  end

  test "catch-all and unknown stay subscribed" do
    %w[catch-all unknown].each do |status|
      contact = Contact.create!(email: "#{status}-#{SecureRandom.hex(3)}@example.com")
      contact.record_verification!(status: status)
      assert contact.reload.subscribed?, status
      assert_not contact.undeliverable?
    end
  end

  test "an earlier unsubscribe reason sticks through a verification" do
    @contact.unsubscribe!(reason: "requested")
    @contact.record_verification!(status: "invalid")
    assert_equal "requested", @contact.reload.unsubscribe_reason
  end

  test "an unknown verification status or unsubscribe reason is refused" do
    assert_raises(ArgumentError) { @contact.record_verification!(status: "maybe") }
    assert_raises(ArgumentError) { @contact.unsubscribe!(reason: "whim") }
    assert_nil @contact.reload.verified_at
  end
end
