# One run of GoogleConnect::GmailEditor against a mailbox: the audit log of
# every Gmail change the hub makes (/tasks/gmail-organize-ability). A dry run
# is logged too (applied false), so the log shows what was looked at before it
# was changed. The row keeps the mailbox address, the action, the Gmail query,
# the label and the counts, never a message id, subject or body. `mailbox` is a
# string, not a key, so the record outlives a disconnect.
class GmailChange < ApplicationRecord
  ACTIONS = %w[read unread archive inbox spam not_spam label unlabel move filter].freeze

  validates :mailbox, :requested_by, presence: true
  validates :action, inclusion: { in: ACTIONS }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_mailbox, ->(mailbox) { where(mailbox: mailbox.to_s.downcase) }
end
