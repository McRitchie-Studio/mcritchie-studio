# One outage of the agent mailbox, as the floor alert (AgentDispatcherAlertJob)
# sees it: opened when a check first fails, resolved when it next passes. The
# unique partial index (one open row per kind) is the dedupe: an incident is
# announced in Discord once (alert_posted_at) and its recovery once
# (recovery_posted_at), however many minutes it lasts.
#
#   dispatcher_silent  no bin/dispatcher ping for AgentDispatcher::SILENT_AFTER
#   message_waiting    a routed message has sat `received` for WAIT_LIMIT
#
# The nightly database-backup sweep (DbBackupSweep, Steffon's agent job) opens
# two more kinds on the same floor, so its alerts post through the same
# once-per-incident announce:
#
#   db_backup_missing       a backed-up app has no completed backup since the 02:00 Denver slot
#   db_backup_sweep_failed  the sweep could not read an app's backups (API down,
#                           bad key), so it cannot say whether one is missing
#
# Two kinds are PER CARD: each open row names its task slug in `subject`, so the
# dedupe is one open row per (kind, subject) instead of one per kind:
#
#   submitted_unclaimed   a submitted card, DoR green, no review claim for 30 min
#   change_build_refused  the build launcher could not start a chat-sourced change
#                         card (bin/task begin refused); the card stays designed
class AgentMailboxIncident < ApplicationRecord
  KINDS = %w[dispatcher_silent message_waiting db_backup_missing db_backup_sweep_failed
             submitted_unclaimed change_build_refused].freeze
  SUBJECT_KINDS = %w[submitted_unclaimed change_build_refused].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :opened_at, presence: true
  validates :subject, presence: true, if: -> { SUBJECT_KINDS.include?(kind) }
  validates :subject, absence: true, unless: -> { SUBJECT_KINDS.include?(kind) }

  scope :unresolved, -> { where(resolved_at: nil) }

  def self.open_for(kind, subject: nil) = unresolved.find_by(kind: kind, subject: subject)

  def open? = resolved_at.nil?
end
