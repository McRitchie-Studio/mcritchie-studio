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

  # [integration] The send stores the id Resend's webhooks will name, and logs
  # the send itself.
  test "perform stores the message id and logs a sent event" do
    BroadcastSendJob.perform_now(@broadcast.id, @contact.id)

    delivery = @broadcast.deliveries.find_by!(contact: @contact)
    assert_equal ActionMailer::Base.deliveries.last.message_id, delivery.provider_message_id
    assert_equal ["sent"], delivery.events.pluck(:kind)
  end

  # [unit] A contact this broadcast already reached is never sent it again
  # (a batch and the editor's send can overlap).
  test "perform skips a contact the broadcast was already sent to" do
    @broadcast.deliveries.create!(contact: @contact, sent_at: 1.hour.ago)

    assert_no_emails { BroadcastSendJob.perform_now(@broadcast.id, @contact.id) }
  end

  # [unit] sent_at is stamped only once the mailer returns, so a failed send is
  # retried instead of being recorded as sent.
  test "a send that raises leaves the delivery unsent for the retry" do
    BroadcastMailer.stub(:campaign, ->(*) { raise Net::ReadTimeout }) do
      assert_raises(Net::ReadTimeout) { BroadcastSendJob.new.perform(@broadcast.id, @contact.id) }
    end
    assert_nil @broadcast.deliveries.find_by!(contact: @contact).sent_at

    assert_emails(1) { BroadcastSendJob.perform_now(@broadcast.id, @contact.id) }
  end

  # [unit] Jobs for one (broadcast, contact) share a solid_queue semaphore of 1,
  # so two can never both pass the sent_at check mid-send; other pairs do not.
  test "one broadcast to one contact runs one job at a time" do
    same = BroadcastSendJob.new(@broadcast.id, @contact.id)
    assert_equal 1, same.concurrency_limit
    assert_equal same.concurrency_key, BroadcastSendJob.new(@broadcast.id, @contact.id).concurrency_key
    assert_not_equal same.concurrency_key, BroadcastSendJob.new(@broadcast.id, @contact.id + 1).concurrency_key
  end

  test "perform never mails an address a verification called undeliverable, even resubscribed" do
    @contact.record_verification!(status: "spamtrap")
    @contact.resubscribe!

    assert_no_emails do
      BroadcastSendJob.perform_now(@broadcast.id, @contact.id)
    end
  end
end
