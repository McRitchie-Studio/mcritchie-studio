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
class AgentMailboxIncident < ApplicationRecord
  KINDS = %w[dispatcher_silent message_waiting db_backup_missing db_backup_sweep_failed].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :opened_at, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }

  def self.open_for(kind) = unresolved.find_by(kind: kind)

  def open? = resolved_at.nil?
end
