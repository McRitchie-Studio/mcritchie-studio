# One outage of the agent mailbox, as the floor alert (AgentDispatcherAlertJob)
# sees it: opened when a check first fails, resolved when it next passes. The
# unique partial index (one open row per kind) is the dedupe: an incident is
# announced in Discord once (alert_posted_at) and its recovery once
# (recovery_posted_at), however many minutes it lasts.
#
#   dispatcher_silent  no bin/dispatcher ping for AgentDispatcher::SILENT_AFTER
#   message_waiting    a routed message has sat `received` for WAIT_LIMIT
class AgentMailboxIncident < ApplicationRecord
  KINDS = %w[dispatcher_silent message_waiting].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :opened_at, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }

  def self.open_for(kind) = unresolved.find_by(kind: kind)

  def open? = resolved_at.nil?
end
