# One Google Workspace we hold agentic access to — and the allow-list that says
# whose mailbox this system may open.
#
# Domain-wide delegation cannot be narrowed at the grant. It authorizes
# impersonation of ANY user in a domain, and the caller picks the subject. So
# "which user do we act as" is the security boundary, and it lives here rather
# than in a caller's argument: Workspace::Credentials will not build an
# authorizer for a subject that is not an ACTIVE row in this table.
#
# The lifecycle is deliberately three states, because "we have not been granted
# access yet" and "our access was taken away" need different responses:
#
#   pending  — registered; the domain's super-admin has not granted delegation,
#              or we have not proved it yet. Impersonation refused.
#   active   — a token was fetched for this subject and the grant is proven.
#   revoked  — deliberately switched off. Impersonation refused, row kept.
class WorkspaceAccount < ApplicationRecord
  STATUSES = %w[pending active revoked].freeze

  # The house convention: every Workspace we are given access to carries a
  # `team@` user, and that user is the one we act as.
  DEFAULT_LOCAL_PART = "team".freeze

  has_many :knowledge_sources, dependent: :nullify

  validates :domain, presence: true, uniqueness: true
  validates :subject, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validate :subject_belongs_to_this_domain

  before_validation :normalize

  scope :active, -> { where(status: "active") }

  def self.default_subject_for(domain) = "#{DEFAULT_LOCAL_PART}@#{domain.to_s.strip.downcase}"

  # The one question Credentials asks before impersonating anyone.
  def self.impersonatable?(subject) = active.exists?(subject: subject.to_s.strip.downcase)

  def active? = status == "active"

  # Proven: a token was issued for this subject, so the grant exists in the
  # right Workspace. Clears any earlier refusal.
  def mark_verified!(at: Time.current)
    update!(status: "active", delegation_verified_at: at, last_check_error: nil)
  end

  # NOT an error state on its own. `unauthorized_client` is what a brand-new
  # grant looks like while it propagates — and also what a grant placed in the
  # WRONG Workspace looks like forever, which is why the reason is recorded
  # rather than reduced to a boolean.
  def mark_unverified!(reason)
    update!(status: (status == "revoked" ? "revoked" : "pending"),
            last_check_error: reason.to_s[0, 250])
  end

  private

  def normalize
    self.domain = domain.to_s.strip.downcase.presence
    self.subject = (subject.presence || self.class.default_subject_for(domain)).to_s.strip.downcase
    self.name = name.presence || domain
  end

  # The cross-tenant mistake, made structurally impossible: a row for one
  # company can never name a subject in another company's domain.
  def subject_belongs_to_this_domain
    return if domain.blank? || subject.blank?
    return if subject.end_with?("@#{domain}")

    errors.add(:subject, "must be an address in #{domain} (got #{subject})")
  end
end
