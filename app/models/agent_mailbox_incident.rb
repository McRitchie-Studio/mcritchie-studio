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
#
# The dispatcher's harness check (AgentDispatcher#harness_failing_beats) opens one
# more floor-wide kind:
#
#   harness_degraded      the Mac's bounded `op whoami` or GitHub check failed on
#                         HARNESS_BEATS consecutive minute pings
#
# EPISODES, for escalation to a person (FloorAlert#escalate). An incident that
# opens within FLAP_WINDOW of the previous same-kind (and same-subject) incident's
# resolution joins that incident's episode: episode_id names the episode's first
# incident (its ROOT; NULL on the root itself), unless that episode has already
# been declared recovered. The root carries the episode's announcements, each
# made once: flap_posted_at (the Discord "flapping" line), escalated_at (the
# escalation email), final_recovery_at (the recovery email, or the declaration
# when no email was owed) and final_posted_at (the Discord line closing a
# flapping episode).
class AgentMailboxIncident < ApplicationRecord
  KINDS = %w[dispatcher_silent message_waiting db_backup_missing db_backup_sweep_failed
             submitted_unclaimed change_build_refused harness_degraded].freeze
  SUBJECT_KINDS = %w[submitted_unclaimed change_build_refused].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :opened_at, presence: true
  validates :subject, presence: true, if: -> { SUBJECT_KINDS.include?(kind) }
  validates :subject, absence: true, unless: -> { SUBJECT_KINDS.include?(kind) }

  # A same-kind incident opening within this long of the last one's resolution
  # is the same episode; FLAP_COUNT opens of an episode within it is flapping.
  FLAP_WINDOW = 1.hour
  FLAP_COUNT = 3

  scope :unresolved, -> { where(resolved_at: nil) }
  scope :roots, -> { where(episode_id: nil) }

  before_create :join_episode

  def self.open_for(kind, subject: nil) = unresolved.find_by(kind: kind, subject: subject)

  def open? = resolved_at.nil?

  def root? = episode_id.nil?
  def root_id = episode_id || id
  def root = root? ? self : self.class.find(episode_id)

  # Every incident of this incident's episode, root first.
  def episode = self.class.where(id: root_id).or(self.class.where(episode_id: root_id)).order(:id)

  # Opens of the episode within FLAP_WINDOW of +now+.
  def flaps(now: Time.current) = episode.where(opened_at: (now - FLAP_WINDOW)..).count

  def flapping?(now: Time.current) = flaps(now: now) >= FLAP_COUNT

  private

  # Join the previous same-kind incident's episode when it resolved within
  # FLAP_WINDOW and its episode is not yet declared recovered.
  def join_episode
    return if episode_id

    previous = self.class.where(kind: kind, subject: subject).where.not(resolved_at: nil).order(:id).last
    return unless previous && previous.resolved_at >= (opened_at || Time.current) - FLAP_WINDOW

    first = previous.root
    self.episode_id = first.id if first.final_recovery_at.nil?
  end
end
