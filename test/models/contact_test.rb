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
end
