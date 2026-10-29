# A manual setup an agent still needs from Alex McRitchie's hands: today a
# Discord bot (the Developer Portal is behind his login and 2FA, so no agent can
# click it), later a Gmail delegation, a wallet or a QuickBooks connection.
# Shown as a checklist card in the Pending agents column of /agents
# (docs/agents/agents/steffon/sops/agent-onboarding.md).
#
# The model is generic; what a kind's steps are and how they read lives in its
# kit (AgentSetups::Kits). One LIVE setup per agent per kind per target: a
# rotation closes the old row and opens a new one.
#
# Status, in order:
#   pending          Alex McRitchie's clicks are not all done
#   checking         he pressed Done; AgentSetupCheckJob checks what the hub can
#   verifying        the hub's checks passed; waiting for Steffon's
#                    `bin/agent-setup verify` on the Mac (the token read, the
#                    Discord identity call, the install)
#   needs_attention  a check failed; status_reason says why, and Done retries
#   ready            verified and installed
#   closed           Steffon closed it (or a rotation replaced it)
#
# NO SECRET IS EVER STORED. `details` carries only public values; the token
# lives in 1Password and on the app's config, and is read only on the Mac.
class AgentSetup < ApplicationRecord
  STATUSES = %w[pending checking verifying needs_attention ready closed].freeze
  OPEN_STATUSES = %w[pending checking verifying needs_attention].freeze
  FINISHED_STATUSES = %w[ready closed].freeze
  # A status Alex McRitchie may press Done from.
  SUBMITTABLE = %w[pending needs_attention].freeze

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, inverse_of: false
  has_many :steps, -> { order(:position) }, class_name: "AgentSetupStep", dependent: :destroy, inverse_of: :agent_setup

  validates :kind, inclusion: { in: ->(_) { AgentSetups::Kits.kinds } }
  validates :status, inclusion: { in: STATUSES }
  validates :target, :opened_by, presence: true
  validate :details_hold_no_secret

  scope :open_setups, -> { where(status: OPEN_STATUSES) }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  # Opens a setup with its kit's steps, all not done. Raises
  # ActiveRecord::RecordNotUnique when a live one exists for the same target.
  def self.open!(agent_slug:, kind:, target:, opened_by:, details: {})
    kit = AgentSetups::Kits.fetch(kind)
    transaction do
      setup = create!(agent_slug: agent_slug, kind: kind.to_s, target: target, opened_by: opened_by,
                      details: kit.default_details(agent_slug).merge(details.compact.stringify_keys))
      kit.step_keys.each_with_index { |key, i| setup.steps.create!(key: key, position: i + 1) }
      setup
    end
  end

  def kit = AgentSetups::Kits.fetch(kind)
  def open? = OPEN_STATUSES.include?(status)
  def finished? = FINISHED_STATUSES.include?(status)
  def submittable? = SUBMITTABLE.include?(status)
  def detail(key) = details.to_h[key.to_s].presence

  # The first step not yet done: the one the card points at.
  def current_step = steps.find { |s| !s.done? }

  # What blocks Done, or nil. The kit names its own requirement (the Discord
  # kit needs the application id).
  def submit_blocker
    return "This setup is #{status.humanize.downcase}." unless submittable?

    kit.submit_blocker(self)
  end

  # Alex McRitchie's Done: every step marked, the status to checking, the
  # hub's check queued. The caller enqueues the job after the commit.
  def submit!(by:, now: Time.current)
    raise ArgumentError, submit_blocker if submit_blocker

    transaction do
      steps.each { |s| s.update!(done_by: by, done_at: now) unless s.done? }
      update!(status: "checking", submitted_by: by, submitted_at: now, status_reason: nil)
    end
  end

  def mark_step!(key, by:, done: true, now: Time.current)
    step = steps.find { |s| s.key == key.to_s } or raise ActiveRecord::RecordNotFound, "no step #{key}"
    raise ArgumentError, "This setup is #{status.humanize.downcase}." unless submittable?

    step.update!(done ? { done_by: by, done_at: now } : { done_by: nil, done_at: nil })
    step
  end

  # The hub's check passed: waiting for Steffon's verify on the Mac.
  def await_verify!(note)
    update!(status: "verifying", status_reason: note)
  end

  def needs_attention!(reason)
    update!(status: "needs_attention", status_reason: reason)
  end

  def ready!(by:, note: nil, now: Time.current)
    update!(status: "ready", verified_by: by, verified_at: now, ready_at: now, status_reason: note)
  end

  def close!(by:, now: Time.current)
    update!(status: "closed", closed_by: by, closed_at: now)
  end

  # Records a fault in /error_logs targeted at this setup, so the row is
  # reachable from the card's own history. Logging never raises: a failed log
  # must not stop the caller moving the card to needs_attention.
  def log_error!(exception, what)
    ErrorLog.capture!(exception).update(target: self, target_name: "agent setup #{id} (#{agent_slug} #{kind}): #{what}")
  rescue StandardError => e
    Rails.logger.error("[AgentSetup#log_error!] could not log #{exception.class} for setup #{id}: #{e.class}")
    nil
  end

  private

  # A belt under the rule: no value that looks like a Discord bot token (three
  # dot-joined base64 segments) or a 1Password secret reference may land in
  # details, so a careless `--detail` cannot store one.
  SECRET_SHAPE = /\A[\w-]{20,}\.[\w-]{5,}\.[\w-]{20,}\z/
  def details_hold_no_secret
    details.to_h.each do |key, value|
      next unless value.is_a?(String)

      errors.add(:details, "#{key} looks like a token; no secret is ever stored here") if value.match?(SECRET_SHAPE)
    end
  end
end
