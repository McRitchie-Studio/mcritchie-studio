require "test_helper"

class UnsubscribesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @contact = Contact.create!(email: "unsubscribe-#{SecureRandom.hex(4)}@example.com", first_name: "Unsub")
  end

  test "show is inert so email scanner prefetch does not unsubscribe" do
    get unsubscribe_path(token: @contact.unsubscribe_token)

    assert_response :success
    assert @contact.reload.subscribed?
    assert_nil @contact.unsubscribed_at
  end

  test "post consumes the unsubscribe token and suppresses future sends" do
    post unsubscribe_path(token: @contact.unsubscribe_token)

    assert_response :success
    assert_not @contact.reload.subscribed?
    assert_not_nil @contact.unsubscribed_at
  end

  test "invalid token renders a safe not found page" do
    post unsubscribe_path(token: "not-real")

    assert_response :success
    assert @contact.reload.subscribed?
  end
end
