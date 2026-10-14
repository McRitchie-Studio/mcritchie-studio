require "test_helper"

# studio-engine's daily health report, as the hub turns it on: scheduled in
# config/recurring.yml, sent to the one recipient config/initializers/studio.rb
# names, with the /contact form's rows as its "Contact messages" section.
class HealthReportJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  # Inside the window that ends at 07:00 Denver on Oct 14, 2026 (13:00 UTC).
  NOW = Time.utc(2026, 10, 14, 13, 0, 30)
  WINDOW = Studio::HealthReport.window(NOW)

  def submission(at:, **attrs)
    ContactSubmission.create!({ name: "Jordan Lee", email: "jordan@example.com", message: "Hello", created_at: at }.merge(attrs))
  end

  test "[integration] it is scheduled daily at 07:00 Denver in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "studio_health_report")

    assert_equal "Studio::HealthReportJob", entry["class"]
    assert_equal "0 7 * * * America/Denver", entry["schedule"]
    assert_equal Studio::HealthReportJob, entry["class"].constantize
  end

  test "[unit] the recipient is the one the Studio initializer names, whatever the env says" do
    ENV.stub(:fetch, ->(*) { "someone-else@example.com" }) do
      assert_equal [ "alex@mcritchie.studio" ], Studio::HealthReport.recipients
    end
  end

  test "[unit] health_report_contacts reads ContactSubmission rows by created_at in the window, newest first" do
    before = submission(at: WINDOW.begin - 1.second, name: "Too Early")
    first = submission(at: WINDOW.begin, name: "Avery Kim", email: "avery@example.com")
    flagged = submission(at: WINDOW.end - 1.hour, name: "Bot Maybe", email: "bot@example.com", spam_reason: "too_fast")
    after = submission(at: WINDOW.end, name: "Too Late")

    rows = Studio.health_report_contacts.call(WINDOW).to_a

    assert_equal [ flagged, first ], rows
    refute_includes rows, before
    refute_includes rows, after, "07:00:00 belongs to the next day's report"
    assert_equal "Avery Kim <avery@example.com>", first.health_report_label
    assert_equal "Bot Maybe <bot@example.com> (flagged: too_fast)", flagged.health_report_label
  end

  test "[integration] the job emails the report, listing the day's contact messages" do
    submission(at: WINDOW.begin + 2.hours, name: "Avery Kim", email: "avery@example.com")
    submission(at: WINDOW.begin + 3.hours, name: "Bot Maybe", email: "bot@example.com", spam_reason: "no_browser_proof")
    submission(at: WINDOW.begin - 1.hour, name: "Yesterday Person")

    assert_emails 1 do
      perform_enqueued_jobs { Studio::HealthReportJob.perform_now(NOW) }
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "alex@mcritchie.studio" ], mail.to
    assert_match(/2 contact messages/, mail.subject)
    body = (mail.text_part || mail).body.decoded
    assert_includes body, "Avery Kim <avery@example.com>"
    assert_includes body, "(flagged: no_browser_proof)"
    assert_not_includes body, "Yesterday Person"
  end

  test "[integration] QA never sends" do
    Studio.stub(:qa_environment?, true) do
      assert_no_emails do
        perform_enqueued_jobs { Studio::HealthReportJob.perform_now(NOW) }
      end
    end
  end
end
