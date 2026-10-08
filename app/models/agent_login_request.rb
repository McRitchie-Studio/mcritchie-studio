# One request for an admin agent session (docs/agents/system/agent-sessions-design.md,
# section 3). `bin/agent-activity heartbeat steffon|xan` posts it; the operator
# grants it one of two ways inside the admin_login window (Devops::Windows):
#
# - the Approve tap on the board (issued_by operator_grant);
# - the one-time code the board shows an admin on the request, which the operator
#   puts in the launch phrase and the requesting harness posts back (issued_by
#   launch_phrase).
#
# The table holds a digest of the code and of the requester's collect key, never
# either value. The code is derived from the app secret and the row, so the board
# can show it again. A pending request past its window is lapsed: nothing is
# stored for that, #state computes it.
class AgentLoginRequest < ApplicationRecord
  STATUSES = %w[pending granted refused].freeze
  # Wrong codes a request takes before it is refused.
  CODE_ATTEMPTS = 5
  # Unlapsed pending requests the table holds at once.
  PENDING_CAP = 5
  CODE_ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789".freeze
  CODE_LENGTH = 8

  # A refusal the API answers with: `kind` picks the status and error code.
  class Refusal < StandardError
    attr_reader :kind

    def initialize(kind, message)
      @kind = kind
      super(message)
    end
  end

  # The collect key, in memory on the instance .request! returns and nowhere else.
  attr_reader :collect_key

  attr_readonly :slug, :soul, :harness_session_id, :phrase_digest, :collect_digest, :requested_at

  validates :slug, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :harness_session_id, :requested_at, presence: true
  validate :soul_is_admin

  before_validation :assign_defaults, on: :create

  scope :pending, -> { where(status: "pending") }

  def self.window_length
    Devops::Windows.minutes("admin_login").minutes
  end

  # Pending requests still inside their window, oldest first.
  def self.awaiting(now = Time.current)
    pending.where("requested_at > ?", now - window_length).order(:requested_at)
  end

  # Post a request. An earlier open one from the same harness for the same soul is
  # refused as superseded, so one harness holds one live code per soul.
  def self.request!(soul:, harness_session_id:)
    transaction do
      value = Task.canonical_soul(soul)
      awaiting.where(soul: value, harness_session_id: harness_session_id.to_s)
          .find_each { |prior| prior.refuse!(by: "reissue", reason: "superseded by a newer request") }
      if awaiting.count >= PENDING_CAP
        raise Refusal.new(:too_many, "#{PENDING_CAP} admin login requests are already pending; wait for one to lapse or be decided")
      end

      create!(soul: value, harness_session_id: harness_session_id.to_s)
    end
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.normalize_code(value)
    value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def window
    Devops::Windows.admin_login(requested_at: requested_at)
  end

  def lapsed?(now = Time.current)
    status == "pending" && window.lapsed?(now)
  end

  # pending | lapsed | granted | refused.
  def state(now = Time.current)
    lapsed?(now) ? "lapsed" : status
  end

  # The one-time code, for an admin's eyes on the board. nil unless the request is
  # still open.
  def code(now = Time.current)
    state(now) == "pending" ? derived_code : nil
  end

  def display_code(now = Time.current)
    code(now)&.scan(/.{4}/)&.join("-")
  end

  # The operator's Approve tap. Returns the admin session.
  def approve!(by:)
    decide { grant!(by: by, issued_by: "operator_grant") }
  end

  # The launch-phrase path: the requesting harness posts the code. A wrong code is
  # counted, and the request is refused at CODE_ATTEMPTS.
  def grant_with_code!(code:, collect_key:, harness_session_id:)
    require_requester!(collect_key, harness_session_id)
    decide do
      next grant!(by: "launch_phrase", issued_by: "launch_phrase") if code_matches?(code)

      attempts = code_attempts + 1
      if attempts >= CODE_ATTEMPTS
        update!(code_attempts: attempts, status: "refused", decided_by: "code_attempts", decided_at: Time.current,
                refusal_reason: "#{CODE_ATTEMPTS} wrong codes")
        Refusal.new(:wrong_code, "wrong code; #{slug} is refused after #{CODE_ATTEMPTS} wrong codes and grants nothing")
      else
        update!(code_attempts: attempts)
        Refusal.new(:wrong_code, "wrong code; #{CODE_ATTEMPTS - attempts} of #{CODE_ATTEMPTS} attempts left on #{slug}")
      end
    end
  end

  # The operator's Decline tap, or a supersede.
  def refuse!(by:, reason:)
    decide do
      update!(status: "refused", decided_by: by.to_s, decided_at: Time.current, refusal_reason: reason.to_s)
      self
    end
  end

  # Hand the granted session's token to the harness that asked, once.
  def collect!(collect_key:, harness_session_id:)
    require_requester!(collect_key, harness_session_id)
    outcome = with_lock do
      refusal = collect_refusal
      next refusal if refusal

      update!(collected_at: Time.current)
      agent_session
    end
    raise outcome if outcome.is_a?(Refusal)

    outcome
  end

  def agent_session
    agent_session_slug.present? ? AgentSession.find_by(slug: agent_session_slug) : nil
  end

  # What the API shows for a request; never the code, the key or a token.
  def summary(now = Time.current)
    {
      "slug" => slug,
      "soul" => soul,
      "status" => state(now),
      "requested_at" => requested_at&.iso8601,
      "ends_at" => window.ends_at.iso8601,
      "decided_by" => decided_by,
      "reason" => state(now) == "lapsed" ? lapse_reason : refusal_reason,
      "agent_session_slug" => agent_session_slug
    }
  end

  private

  # Run a decision under the row lock. The block returns its result, or a Refusal
  # to raise once the lock's transaction has committed (a counted wrong code must
  # persist).
  def decide
    outcome = with_lock do
      refusal = decision_refusal
      refusal || yield
    end
    raise outcome if outcome.is_a?(Refusal)

    outcome
  end

  def grant!(by:, issued_by:)
    session = AgentSession.create!(soul: soul, tier: "admin", issued_by: issued_by, harness_session_id: harness_session_id)
    update!(status: "granted", decided_by: by.to_s, decided_at: Time.current, agent_session_slug: session.slug)
    session
  end

  # Why this request can no longer be decided, or nil while it is open.
  def decision_refusal(now = Time.current)
    case state(now)
    when "pending" then nil
    when "lapsed" then Refusal.new(:lapsed, lapse_reason)
    when "granted" then Refusal.new(:decided, "#{slug} was already granted by #{decided_by}; its code is spent")
    else Refusal.new(:refused, "#{slug} was refused: #{refusal_reason}")
    end
  end

  def collect_refusal(now = Time.current)
    case state(now)
    when "pending" then Refusal.new(:pending, "#{slug} is pending; its window ends at #{window.ends_at.utc.iso8601}")
    when "lapsed" then Refusal.new(:lapsed, lapse_reason)
    when "refused" then Refusal.new(:refused, "#{slug} was refused: #{refusal_reason}")
    else
      return Refusal.new(:collected, "#{slug}'s token was already collected at #{collected_at.utc.iso8601}") if collected_at

      reason = agent_session ? agent_session.refusal_reason(now) : "#{slug} names no agent session"
      reason && Refusal.new(:refused, reason)
    end
  end

  def lapse_reason
    "#{slug} lapsed at #{window.ends_at.utc.iso8601} with no grant; nothing was minted"
  end

  def require_requester!(collect_key, harness_session_id)
    key_ok = ActiveSupport::SecurityUtils.secure_compare(self.class.digest(collect_key), collect_digest)
    return if key_ok && harness_session_id.to_s == self.harness_session_id

    raise Refusal.new(:forbidden, "#{slug} belongs to the harness session that requested it")
  end

  def code_matches?(code)
    ActiveSupport::SecurityUtils.secure_compare(self.class.digest(self.class.normalize_code(code)), phrase_digest)
  end

  def derived_code
    key = Rails.application.key_generator.generate_key("agent_login_request_code", 32)
    number = OpenSSL::HMAC.hexdigest("SHA256", key, "#{slug}:#{requested_at.to_i}").to_i(16)
    Array.new(CODE_LENGTH) do
      number, index = number.divmod(CODE_ALPHABET.length)
      CODE_ALPHABET[index]
    end.join
  end

  def assign_defaults
    self.soul = Task.canonical_soul(soul) if soul.present?
    self.slug ||= "login-#{SecureRandom.hex(8)}"
    self.requested_at ||= Time.current
    self.phrase_digest ||= self.class.digest(derived_code)
    @collect_key = SecureRandom.urlsafe_base64(32)
    self.collect_digest ||= self.class.digest(@collect_key)
  end

  def soul_is_admin
    return if AgentSession.tier_for_soul(soul) == "admin"

    errors.add(:soul, "#{soul.inspect} holds no admin tier; an admin login is for #{AgentSession::ADMIN_SOULS.join(" and ")}")
  end
end
