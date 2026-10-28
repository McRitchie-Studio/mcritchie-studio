# The 5th-of-the-month bookkeeping reminder (Books::Reminder), registered in
# config/recurring.yml for production. Best-effort, like DeskHealthJob: a
# failure is an ErrorLog receipt, never a retry storm, and the delivery's
# idempotency key keeps a rerun from posting twice.
class BooksReminderJob < ApplicationJob
  def perform(reminder: Books::Reminder.new)
    return if Studio.qa_environment?

    reminder.call
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
