require "test_helper"

class StudioEmailDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    @user = users(:alex)
  end

  test "deliver records a durable row and enqueues the shared delivery job" do
    delivery = nil
    assert_enqueued_with(job: Studio::EmailDeliveryJob) do
      assert_difference "Studio::EmailDelivery.count", 1 do
        delivery = Studio::Email.deliver(UserMailer, :magic_link, @user.email, "tok", to: @user.email, user: @user)
      end
    end

    assert_equal "UserMailer#magic_link", delivery.email_key
    assert_equal @user.email, delivery.to
    assert_equal @user, delivery.user
    assert_not delivery.sent?
  end

  test "deliver_now sends the stored mailer call and marks the row sent" do
    delivery = Studio::EmailDelivery.deliver(UserMailer, :magic_link, @user.email, "tok", to: @user.email, user: @user)

    assert_emails 1 do
      delivery.deliver_now!
    end

    assert delivery.reload.sent?
    assert_not_nil delivery.sent_at
    assert_equal [@user.email], ActionMailer::Base.deliveries.last.to
  end

  test "resend_unsent re-enqueues unsent rows" do
    Studio::EmailDelivery.deliver(UserMailer, :magic_link, @user.email, "sent", to: @user.email).update!(sent: true)
    Studio::EmailDelivery.deliver(UserMailer, :magic_link, @user.email, "unsent", to: @user.email)

    assert_enqueued_jobs 1, only: Studio::EmailDeliveryJob do
      Studio::EmailDelivery.resend_unsent!
    end
  end
end
