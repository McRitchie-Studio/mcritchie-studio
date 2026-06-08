require "test_helper"

class BroadcastMailerTest < ActiveSupport::TestCase
  setup do
    @broadcast = Broadcast.create!(
      subject: "We built you a new game",
      template_key: "new_game_announcement",
      survivor_url: "https://example.com/sv",
      turf_totals_url: "https://example.com/tt"
    )
    @contact = Contact.create!(email: "sam@example.com", first_name: "Sam")
  end

  test "campaign personalizes the greeting and includes an absolute unsubscribe link" do
    mail = BroadcastMailer.campaign(@broadcast, @contact)
    assert_equal ["sam@example.com"], mail.to
    body = (mail.html_part&.body || mail.body).to_s
    assert_includes body, "Hi Sam", "greeting should personalize from the contact's first name"
    assert_match %r{https?://[^"]+/unsubscribe/#{@contact.unsubscribe_token}}, body
    # No tracking artifacts when there's no delivery (e.g. in-app preview path).
    refute_match %r{/e/o/}, body
  end

  test "campaign with a delivery injects the open pixel and click-tracking links" do
    delivery = @broadcast.deliveries.create!(contact: @contact)
    mail = BroadcastMailer.campaign(@broadcast, @contact, delivery)
    body = (mail.html_part&.body || mail.body).to_s
    assert_match %r{/e/o/#{delivery.token}}, body, "open pixel"
    assert_match %r{/e/c/#{delivery.token}\?l=turf_totals}, body, "click-tracked CTA"
  end
end
