require "test_helper"

class BroadcastSendJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @broadcast = Broadcast.create!(
      subject: "Job smoke",
      template_key: "new_game_announcement",
      hero_url: "https://example.com/hero",
      survivor_url: "https://example.com/survivor",
      turf_totals_url: "https://example.com/turf"
    )
    @contact = Contact.create!(email: "job-#{SecureRandom.hex(4)}@example.com", first_name: "Job")
  end

  test "perform creates a delivery record and sends the campaign email" do
    assert_emails 1 do
      assert_difference "BroadcastDelivery.count", 1 do
        BroadcastSendJob.perform_now(@broadcast.id, @contact.id)
      end
    end

    delivery = @broadcast.deliveries.find_by!(contact: @contact)
    assert_not_nil delivery.sent_at
    assert_equal [@contact.email], ActionMailer::Base.deliveries.last.to
  end

  test "perform reuses an existing delivery token for retries" do
    delivery = @broadcast.deliveries.create!(contact: @contact)

    assert_emails 1 do
      assert_no_difference "BroadcastDelivery.count" do
        BroadcastSendJob.perform_now(@broadcast.id, @contact.id)
      end
    end

    assert_equal delivery.token, @broadcast.deliveries.find_by!(contact: @contact).token
  end

  test "perform suppresses contacts that unsubscribed before the job runs" do
    @contact.unsubscribe!

    assert_no_emails do
      assert_no_difference "BroadcastDelivery.count" do
        BroadcastSendJob.perform_now(@broadcast.id, @contact.id)
      end
    end
  end
end
