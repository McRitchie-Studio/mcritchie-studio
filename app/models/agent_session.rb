# One soul logged in at one tier: the server-owned half of an agent login
# (docs/agents/system/agent-sessions-design.md). The bearer token an agent holds
# is a signed message carrying only this row's slug, so the row decides on every
# call: a revoke or an expiry here ends the session at once.
#
# Tiers and their scope:
# - studio: a builder or reviewer. Scoped to ONE task (task_slug required), and
#   live only while that task is building or under review.
# - admin: Steffon and Xan. Unscoped within the admin tier; task_slug is always
#   null, because the tier is the scope.
# - client: Turf Monster and Tyrion. The model and the tier only; no endpoint
#   accepts a client session yet.
#
# A tier is set at login and never raised: the soul decides which tiers it may
# hold, and nothing updates a row's tier, soul or scope after create.
class AgentSession < ApplicationRecord
  TIERS = %w[admin studio client].freeze
  ADMIN_SOULS = %w[steffon xan].freeze
  CLIENT_SOULS = %w[turf-monster tyrion].freeze
  ISSUERS = %w[task_claim review_claim operator_grant launch_phrase runtime_key].freeze
  STUDIO_ISSUERS = %w[task_claim review_claim].freeze
  # A studio session ends when its task leaves these stages.
  STUDIO_LIVE_STAGES = %w[building submitted].freeze
  TTL = { "studio" => 24.hours, "admin" => 8.hours, "client" => 24.hours }.freeze
  TOKEN_PURPOSE = :agent_session

  attr_readonly :slug, :soul, :tier, :task_slug, :issued_by, :issued_at

  validates :slug, presence: true, uniqueness: true
  validates :tier, inclusion: { in: TIERS }
  validates :issued_by, inclusion: { in: ISSUERS }
  validates :issued_at, :expires_at, presence: true
  validate :soul_holds_tier
  validate :scope_matches_tier

  before_validation :assign_defaults, on: :create

  scope :unrevoked, -> { where(revoked_at: nil) }
  scope :unexpired, -> { where("expires_at > ?", Time.current) }
  scope :for_task, ->(slug) { where(task_slug: slug) }

  # The tier a soul's own sessions are capped at, or nil for a slug that is no soul.
  def self.tier_for_soul(soul)
    value = Task.canonical_soul(soul)
    return nil unless Task.soul?(value)
    return "admin" if ADMIN_SOULS.include?(value)
    return "client" if CLIENT_SOULS.include?(value)

    "studio"
  end

  # Log a studio soul in to one task. Revokes that soul's earlier live sessions on
  # the same task, so a re-claim leaves one live row.
  def self.issue_studio!(soul:, task:, issued_by:, harness_session_id: nil)
    transaction do
      unrevoked.for_task(task.slug).where(soul: Task.canonical_soul(soul), tier: "studio")
               .find_each { |prior| prior.revoke!(by: "reissue") }
      create!(soul: soul, tier: "studio", task_slug: task.slug, issued_by: issued_by,
              harness_session_id: harness_session_id)
    end
  end

  # Why `soul` may not take a studio login to `task` by `issued_by`, or nil when it
  # may. The machine credential presents the login, so the soul is never taken from
  # the request alone: the task record names who is entitled to it.
  # - task_claim: a soul the build claim recorded (devops.built_by or
  #   devops.builders). `bin/task begin` logs in as exactly that soul, the one it
  #   stamps the desk's identity with.
  # - review_claim: a reviewer the task names (its stored pair or the live review
  #   claim's holder) who did not build it.
  def self.studio_login_refusal(soul:, task:, issued_by:)
    value = Task.canonical_soul(soul)
    builders = ([task.devops_built_by] + task.devops_builders).compact.uniq
    case issued_by
    when "task_claim"
      return nil if builders.include?(value)

      "#{value} is not #{task.slug}'s builder (the claim recorded #{builders.join(", ").presence || "none"}); " \
        "a task_claim login names the soul the claim stamped"
    when "review_claim"
      return "#{value} built #{task.slug}, so it cannot log in as its reviewer" if builders.include?(value)

      reviewers = (task.reviewers.map { |r| r["slug"] } + [task.review_holder])
                  .map { |slug| Task.canonical_soul(slug) }.reject(&:empty?).uniq
      return nil if reviewers.include?(value)

      "#{value} is not a reviewer #{task.slug} names (#{reviewers.join(", ").presence || "none"})"
    else
      "issued_by must be one of #{STUDIO_ISSUERS.join(", ")}"
    end
  end

  # The session a token names, or nil when the token is not a session token at all
  # (a bad signature, another purpose, an expired message). A row that exists but
  # is no longer live is still returned: the caller answers with #refusal_reason.
  def self.from_token(token)
    data = verifier.verified(token.to_s, purpose: TOKEN_PURPOSE)
    slug = data.is_a?(Hash) ? (data["sid"] || data[:sid]) : nil
    slug.present? ? find_by(slug: slug) : nil
  rescue ArgumentError, TypeError
    nil
  end

  def self.verifier
    Rails.application.message_verifier("agent_session")
  end

  # The row's expires_at is the session's expiry, and the API answers a call past
  # it with the reason. The signed message carries its own expiry a day later as
  # the backstop, so a token dies even if its row were somehow kept alive.
  TOKEN_GRACE = 1.day

  def token
    self.class.verifier.generate({ "sid" => slug }, purpose: TOKEN_PURPOSE, expires_at: expires_at + TOKEN_GRACE)
  end

  def admin? = tier == "admin"
  def studio? = tier == "studio"
  def client? = tier == "client"

  def revoked? = revoked_at.present?
  def expired?(now = Time.current) = expires_at <= now

  # Why this session may not be used right now, or nil when it is live. The API
  # answers 401 with this sentence.
  def refusal_reason(now = Time.current)
    return "agent session #{slug} was revoked#{" by #{revoked_by}" if revoked_by.present?}" if revoked?
    return "agent session #{slug} expired at #{expires_at.utc.iso8601}" if expired?(now)
    return nil unless studio?

    stage = Task.where(slug: task_slug).pick(:stage)
    return "agent session #{slug} names task #{task_slug}, which no longer exists" if stage.nil?
    return nil if STUDIO_LIVE_STAGES.include?(stage)

    "agent session #{slug} ended when #{task_slug} left building and review (it is #{stage})"
  end

  def live?(now = Time.current) = refusal_reason(now).nil?

  # May this session write the task named? Admin: any task. Studio: its own task
  # only. Client: none.
  def covers_task?(slug)
    return true if admin?
    return false unless studio?

    task_slug.present? && task_slug == slug.to_s
  end

  def revoke!(by:)
    return if revoked?

    update!(revoked_at: Time.current, revoked_by: by.to_s.presence)
  end

  # What the board and the API show for a session; never the token.
  def summary
    {
      "slug" => slug,
      "soul" => soul,
      "tier" => tier,
      "task_slug" => task_slug,
      "issued_by" => issued_by,
      "issued_at" => issued_at&.iso8601,
      "expires_at" => expires_at&.iso8601,
      "revoked_at" => revoked_at&.iso8601
    }
  end

  private

  def assign_defaults
    self.soul = Task.canonical_soul(soul) if soul.present?
    self.slug ||= "sess-#{SecureRandom.hex(8)}"
    self.issued_at ||= Time.current
    self.expires_at ||= issued_at + TTL.fetch(tier.to_s, TTL["studio"])
  end

  # Admin is for the admin souls only, client for the client souls only; studio is
  # any soul that is not a client. An admin soul may still hold a studio session
  # (a reviewer light scoped to one task), which narrows it rather than raising it.
  def soul_holds_tier
    capped = self.class.tier_for_soul(soul)
    if capped.nil?
      errors.add(:soul, "#{soul.inspect} is not a soul in config/souls.yml")
    elsif tier == "admin" && capped != "admin"
      errors.add(:tier, "admin is held only by #{ADMIN_SOULS.join(" and ")}, not #{soul}")
    elsif tier == "client" && capped != "client"
      errors.add(:tier, "client is held only by #{CLIENT_SOULS.join(" and ")}, not #{soul}")
    elsif tier == "studio" && capped == "client"
      errors.add(:tier, "#{soul} is a client soul and holds no studio session")
    end
  end

  def scope_matches_tier
    case tier
    when "admin"
      errors.add(:task_slug, "must be empty: an admin session is unscoped within the admin tier") if task_slug.present?
    when "studio"
      errors.add(:task_slug, "is required: a studio session is scoped to one task") if task_slug.blank?
      if issued_by.present? && !STUDIO_ISSUERS.include?(issued_by)
        errors.add(:issued_by, "a studio session is issued by #{STUDIO_ISSUERS.join(" or ")}")
      end
    end
  end
end
