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

  # [integration] The analytics credit an unsubscribe to the email it came from.
  test "an unsubscribe from an email is logged against that email, once" do
    broadcast = Broadcast.create!(subject: "Hi", template_key: "cyvasse_is_back")
    delivery = broadcast.deliveries.create!(contact: @contact)

    get unsubscribe_path(token: @contact.unsubscribe_token, d: delivery.token)
    assert_select "form[action*='d=#{delivery.token}']"
    2.times { post unsubscribe_path(token: @contact.unsubscribe_token, d: delivery.token) }

    assert_equal 1, delivery.events.of_kind("unsubscribed").count
    assert_not_nil delivery.reload.unsubscribed_at
    assert_equal "requested", @contact.reload.unsubscribe_reason
  end

  test "a d token for someone else's email is ignored" do
    other = Contact.create!(email: "other-#{SecureRandom.hex(3)}@example.com")
    delivery = Broadcast.create!(subject: "Hi", template_key: "cyvasse_is_back").deliveries.create!(contact: other)

    post unsubscribe_path(token: @contact.unsubscribe_token, d: delivery.token)
    assert_not @contact.reload.subscribed?
    assert_equal 0, EmailEvent.count
  end
end
