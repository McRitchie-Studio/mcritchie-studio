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
#              A TERMINAL state as far as any automatic path is concerned:
#              nothing reactivates it, and #reinstate! returns it only to
#              `pending`, which still has to prove delegation again.
class WorkspaceAccount < ApplicationRecord
  STATUSES = %w[pending active revoked].freeze

  # Raised when something tries to ACTIVATE a revoked row. Never rescued into a
  # verdict — a caller reaching this has a bug, and a quiet no-op it ignores is
  # how the kill switch would come undone a second time.
  class Revoked < StandardError; end

  # The house convention: every Workspace we are given access to carries a
  # `team@` user, and that user is the one we act as.
  DEFAULT_LOCAL_PART = "team".freeze

  has_many :knowledge_sources, dependent: :nullify

  # A domain is dot-separated labels, each starting and ending alphanumeric.
  # This rejects the two shapes that validated before and should not have:
  # a TRAILING DOT ("mason.test.") and a bare single label ("localhost").
  DOMAIN_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  validates :domain, presence: true, uniqueness: true,
                     format: { with: DOMAIN_FORMAT, allow_blank: true,
                               message: "must be a dot-separated domain with no trailing dot" }
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
  #
  # A REVOKED row is never resurrected here. Revocation is the one compensating
  # control for turning a compile-time constant into a runtime row, so it must
  # not be undone by a sweep that happens to find the Google-side grant still
  # live — only by #reinstate!, which a human runs by name. This RAISES where
  # mark_unverified! merely keeps the status, because the two directions are not
  # symmetric: failing to deactivate is safe, and activating by accident opens a
  # mailbox. A caller that has not thought about revoked rows finds out here
  # rather than in an access log.
  def mark_verified!(at: Time.current)
    if status == "revoked"
      raise Revoked, "#{domain} is revoked — impersonation stays refused. " \
                     "bin/rails 'workspace:reinstate[#{domain}]' puts it back to pending, " \
                     "and delegation must then be proven again."
    end

    update!(status: "active", delegation_verified_at: at, last_check_error: nil)
  end

  # The kill switch. Any status -> revoked, and impersonation is refused from
  # the next call. The row and its knowledge_sources are KEPT, so the history of
  # what we read survives switching the access off.
  #
  # This is the LOCAL half only: it does not withdraw the Google-side grant.
  # Ending that takes the domain's own super-admin removing our client id.
  def revoke!(reason = nil)
    self.notes = [ notes.presence, "#{Date.current.iso8601} revoked: #{reason}" ].compact.join("\n") if reason.present?
    update!(status: "revoked")
  end

  # The ONLY way back from revoked — and it does not restore access. The row
  # returns to `pending`, which is still refused, and the grant has to be proven
  # again before anything may impersonate the subject. So undoing a kill switch
  # takes a human naming the domain AND a live grant: two deliberate acts,
  # neither of which any sweep can perform on its own.
  def reinstate!
    raise ArgumentError, "#{domain} is #{status}, not revoked — nothing to reinstate" unless status == "revoked"

    update!(status: "pending", delegation_verified_at: nil, last_check_error: nil)
  end

  # NOT an error state on its own. `unauthorized_client` is what a brand-new
  # grant looks like while it propagates — and also what a grant placed in the
  # WRONG Workspace looks like forever, which is why the reason is recorded
  # rather than reduced to a boolean.
  def mark_unverified!(reason)
    update!(status: (status == "revoked" ? "revoked" : "pending"),
            last_check_error: reason.to_s[0, 250])
  end

  # The grant is PROVEN — a token was issued — but a follow-up read failed.
  #
  # Status is deliberately untouched. Dropping to `pending` would discard a
  # proven delegation because of a transient read, and the row would then lie in
  # the other direction. What was wrong before is that the sweep printed
  # CHECK FAILED while the row stayed `active` with last_check_error nil, so the
  # stored state contradicted what the operator was told.
  def record_check_warning!(reason)
    update!(last_check_error: reason.to_s[0, 250])
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

    # One @, checked FIRST: "team@evil.test@mason.test" ends with the right
    # domain and is still two addresses. The mailbox it would open is this
    # domain's either way, so this closes a shape rather than a live hole.
    unless subject.count("@") == 1
      errors.add(:subject, "must be a single email address (got #{subject})")
      return
    end

    # "@mason.test" has exactly one @ and ends with the right domain, and names
    # nobody. It would be handed to Google as the subject of a JWT.
    if subject.start_with?("@")
      errors.add(:subject, "must have a local part before the @ (got #{subject})")
      return
    end
    return if subject.end_with?("@#{domain}")

    errors.add(:subject, "must be an address in #{domain} (got #{subject})")
  end
end
