# frozen_string_literal: true

require "test_helper"

# [integration] BooksReminderJob: scheduled on the 5th, runs the reminder, and a
# failure leaves an ErrorLog receipt instead of raising into the queue's retry.
class BooksReminderJobTest < ActiveJob::TestCase
  test "[integration] the job is scheduled at 08:00 Denver on the 5th in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "books_reminder")

    assert_equal "BooksReminderJob", entry["class"]
    assert_equal "0 8 5 * * America/Denver", entry["schedule"]
    assert ReportDestinations.registered?(Books::Reminder::REPORT_KEY)
  end

  test "[integration] a failing reminder is captured, not raised" do
    failing = Object.new
    def failing.call = raise(StandardError, "drive down")

    assert_difference -> { ErrorLog.count }, 1 do
      BooksReminderJob.perform_now(reminder: failing)
    end
  end
end
