# One draft this system wrote into a mailbox: who asked for it, which mailbox it
# was written AS, and where it sits in Gmail.
#
# The draft itself lives in Gmail and is never copied here — no body is stored.
# `mailbox_address` repeats the mailbox's address on purpose, so a workspace's
# log exports as a file that reads without this database (the acquisition
# handoff).
class MailboxDraft < ApplicationRecord
  belongs_to :workspace_mailbox

  validates :mailbox_address, :drafted_by, :gmail_draft_id, presence: true

  before_validation { self.mailbox_address ||= workspace_mailbox&.address }
end
