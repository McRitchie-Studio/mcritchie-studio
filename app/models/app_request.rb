# One app someone asked McRitchie Studio to build through /build.
#
# The funnel, in states:
#
#   draft    — the prompt was sent. May have no user yet: the visitor is on the
#              sign-in detour, and the draft is found again by its secret `token`.
#   queued   — signed in and a subdomain claimed. A board task now exists for an
#              agent to pick up (`task_slug`).
#   building — an agent is on it.
#   live     — served at <subdomain>.mcritchie.studio.
#   cancelled
#
# Builds are ASYNCHRONOUS and done by agents; nothing here generates an app.
# Phase 1 only RESERVES the subdomain: mcritchie.studio has no wildcard DNS, so
# the agent delivering the build points the name at it.
class AppRequest < ApplicationRecord
  STATUSES = %w[draft queued building live cancelled].freeze
  # A request that holds its subdomain. A cancelled one releases it.
  HOLDING = %w[queued building live].freeze

  PARENT_DOMAIN = "mcritchie.studio".freeze
  PROMPT_LIMIT = 4000

  # 3-30 characters of a-z, 0-9 and hyphens, starting and ending alphanumeric —
  # a valid DNS label that also reads as a name.
  SUBDOMAIN_FORMAT = /\A[a-z0-9][a-z0-9-]{1,28}[a-z0-9]\z/

  # Names that route somewhere of ours, or plausibly will. The satellites'
  # subdomains are added from config/satellites.yml, so a new satellite is
  # reserved the day it is registered, not the day someone notices.
  RESERVED = %w[
    www app api admin qa staging dev test demo status docs help support blog
    mail email smtp imap pop ftp ns ns1 ns2 cdn static assets auth login signin
    signup register account billing build stack packages credentials v1
    mcritchie studio team security root
  ].freeze

  belongs_to :user, optional: true

  validates :token, presence: true, uniqueness: true
  validates :prompt, presence: true, length: { maximum: PROMPT_LIMIT }
  validates :status, inclusion: { in: STATUSES }
  validates :tier, inclusion: { in: -> (_) { WorkspacePackage.keys } }
  validates :subdomain, presence: true, unless: :draft?
  validate :subdomain_is_claimable, if: -> { subdomain.present? && (new_record? || will_save_change_to_subdomain?) }
  validate :one_free_app_per_account, if: -> { user && tier == "launch" && HOLDING.include?(status) }

  before_validation :normalize
  before_validation -> { self.token ||= SecureRandom.urlsafe_base64(18) }, on: :create

  scope :holding, -> { where(status: HOLDING) }
  scope :recent, -> { order(created_at: :desc) }

  def self.reserved_names
    satellites = Rails.root.join("config/satellites.yml")
    hosts = YAML.safe_load_file(satellites).fetch("satellites", []).filter_map do |sat|
      host = URI.parse(sat["production_url"].to_s).host.to_s
      host.delete_suffix(".#{PARENT_DOMAIN}") if host.end_with?(".#{PARENT_DOMAIN}")
    rescue URI::InvalidURIError
      nil
    end
    (RESERVED + hosts).uniq
  end

  # Why NAME cannot be claimed, or nil when it can. The one answer the live
  # availability check and the model's validation both give.
  def self.unavailable_reason(name, except: nil)
    name = normalize_subdomain(name)
    return "Use 3 to 30 letters, numbers or hyphens, starting and ending with a letter or number." unless name.match?(SUBDOMAIN_FORMAT)
    return "That name is reserved." if reserved_names.include?(name)

    taken = holding.where(subdomain: name)
    taken = taken.where.not(id: except.id) if except&.persisted?
    return "That name is taken." if taken.exists?

    nil
  end

  def self.normalize_subdomain(name) = name.to_s.strip.downcase.delete_suffix(".#{PARENT_DOMAIN}")

  def draft? = status == "draft"

  def queued? = status == "queued"

  def url = subdomain.present? ? "https://#{subdomain}.#{PARENT_DOMAIN}" : nil

  def host = subdomain.present? ? "#{subdomain}.#{PARENT_DOMAIN}" : nil

  # Sign-in attaches a draft to whoever finished it. A draft already attached
  # belongs to that user only.
  def claimable_by?(candidate) = user.nil? || user == candidate

  # Claim SUBDOMAIN and queue the build: the request moves to `queued` and a
  # board task opens for an agent, in one transaction, so a queued request
  # always has its task and a task never outlives a failed claim.
  def queue!(name)
    transaction do
      self.subdomain = name
      self.status = "queued"
      self.queued_at = Time.current
      save!
      task = Task.create!(
        # Four words whatever the name: the board requires a 3-5 word title, and
        # a hyphenated subdomain stays one word.
        title: "Build Launch App #{subdomain}",
        stage: "designed",
        priority: 1,
        description: "Launch-tier app requested through /build by #{user&.email || 'unknown'}.",
        metadata: { "devops" => {
          "kind" => "feature",
          "acceptance" => [ "#{host} serves the app the requester described" ],
          "agent_context" => "Prompt from the requester, verbatim:\n\n#{prompt}\n\n" \
                             "Subdomain reserved: #{host}. Tier: #{tier}. App request token: #{token}."
        } }
      )
      update!(task_slug: task.slug)
    end
    self
  end

  private

  def normalize
    self.prompt = prompt.to_s.strip.presence
    self.subdomain = self.class.normalize_subdomain(subdomain).presence
  end

  def subdomain_is_claimable
    reason = self.class.unavailable_reason(subdomain, except: self)
    errors.add(:subdomain, reason) if reason
  end

  def one_free_app_per_account
    others = self.class.holding.where(user: user, tier: "launch")
    others = others.where.not(id: id) if persisted?
    errors.add(:base, "Your free plan includes one app, and you already have one.") if others.exists?
  end
end
