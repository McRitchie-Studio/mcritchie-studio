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

  test "a malformed d parameter still unsubscribes without an error" do
    post unsubscribe_path(token: @contact.unsubscribe_token), params: { d: [ "x" ] }
    assert_response :success
    assert_not @contact.reload.subscribed?
  end

  # [integration] Task unsubscribe-and-resubscribe: the page says whose address
  # and which email, one button unsubscribes (also as the mail client's
  # one-click POST, which carries no form token), and the landing resubscribes.
  def cyvasse_delivery
    Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back").deliveries.create!(contact: @contact)
  end

  test "the confirm page shows the address and the email it came from" do
    delivery = cyvasse_delivery
    get unsubscribe_path(token: @contact.unsubscribe_token, d: delivery.token)

    assert_select "[data-unsubscribe-email]", text: @contact.email
    assert_select "[data-unsubscribe-broadcast]", text: "“Cyvasse is back”"
    assert_select "form[action*='d=#{delivery.token}'] button", text: "Unsubscribe"
    assert @contact.reload.subscribed?, "the page alone changes nothing"
  end

  test "a mail client's one-click POST unsubscribes without a form token" do
    ActionController::Base.allow_forgery_protection = true
    post unsubscribe_path(token: @contact.unsubscribe_token), params: { "List-Unsubscribe" => "One-Click" }
    assert_response :success
    assert_not @contact.reload.subscribed?
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "the landing offers resubscribe, which restores the contact and logs it" do
    delivery = cyvasse_delivery
    post unsubscribe_path(token: @contact.unsubscribe_token, d: delivery.token)
    assert_select "h1", text: "You're unsubscribed"
    assert_select "form[action^='/unsubscribe/#{@contact.unsubscribe_token}/resubscribe'] button", text: "Resubscribe"

    post resubscribe_path(token: @contact.unsubscribe_token, d: delivery.token)
    assert_select "h1", text: "Welcome back"
    assert @contact.reload.subscribed?
    assert_nil @contact.unsubscribe_reason
    assert_equal %w[unsubscribed resubscribed], delivery.events.order(:id).pluck(:kind)
  end

  test "an unsubscribed reader opening the link again is offered resubscribe" do
    @contact.unsubscribe!
    get unsubscribe_path(token: @contact.unsubscribe_token)
    assert_select "h1", text: "You're already unsubscribed"
    assert_select "button", text: "Resubscribe"
  end

  test "resubscribe with a bad token changes nothing" do
    post resubscribe_path(token: "not-real")
    assert_response :success
    assert_select "h1", text: "Link not found"
  end
end
