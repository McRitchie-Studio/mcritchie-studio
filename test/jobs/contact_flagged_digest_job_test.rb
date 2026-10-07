require "test_helper"

# ContactFlaggedDigestJob — the daily email that keeps a wrongly flagged /contact
# visitor from vanishing. What matters: one email when something was flagged,
# none on a quiet day, and an old flag does not keep it sending.
class ContactFlaggedDigestJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  def submission(**attrs)
    ContactSubmission.create!({ name: "Jordan Lee", email: "jordan@example.com", message: "Hello" }.merge(attrs))
  end

  test "[integration] a flagged submission in the last day sends one digest to Alex" do
    submission(spam_reason: "no_browser_proof")
    submission(spam_reason: "too_fast")

    assert_emails 1 do
      perform_enqueued_jobs { ContactFlaggedDigestJob.perform_now }
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal ["alex@mcritchie.studio"], mail.to
    assert_equal "Contact form: 2 flagged as spam in the last day", mail.subject
  end

  test "[integration] nothing flagged means no email, even with real submissions" do
    submission

    assert_no_emails do
      perform_enqueued_jobs { ContactFlaggedDigestJob.perform_now }
    end
  end

  test "[integration] a flag older than the window does not send" do
    old = submission(spam_reason: "too_fast")
    ContactSubmission.where(id: old.id).update_all(created_at: 2.days.ago)

    assert_no_emails do
      perform_enqueued_jobs { ContactFlaggedDigestJob.perform_now }
    end
  end

  test "[integration] a failure leaves an ErrorLog receipt and does not raise" do
    submission(spam_reason: "too_fast")

    Studio::Email.stub(:deliver, ->(*, **) { raise IOError, "outbox is down" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        ContactFlaggedDigestJob.perform_now
      end
    end
  end

  test "[integration] it is scheduled daily in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "contact_flagged_digest")

    assert_equal "ContactFlaggedDigestJob", entry["class"]
    assert_equal "0 7 * * * America/Denver", entry["schedule"]
  end

  test "[unit] the window starts at the previous 07:00 Denver, across DST and a late run" do
    # Fall-back day: the 07:00 runs are 25 hours apart, so a 24h window misses one.
    assert_equal Time.utc(2026, 10, 31, 13), ContactFlaggedDigestJob.window_start(Time.utc(2026, 11, 1, 14, 0, 5))
    # A run that lands 40s late still starts where yesterday's on-time run did.
    assert_equal Time.utc(2026, 10, 6, 13), ContactFlaggedDigestJob.window_start(Time.utc(2026, 10, 7, 13, 0, 40))
  end
end
