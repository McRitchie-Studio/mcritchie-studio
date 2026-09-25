# One Google Workspace we hold agentic access to — and the allow-list that says
# whose mailbox this system may open.
#
# Domain-wide delegation cannot be narrowed at the grant. It authorizes
# impersonation of ANY user in a domain, and the caller picks the subject. So
# "which user do we act as" is the security boundary, and it lives here rather
# than in a caller's argument: Workspace::Credentials will not build an
# authorizer for a subject that is not an ACTIVE row in this table.
#
# The lifecycle is deliberately four states, because "we have not been granted
# access yet" and "our access was taken away" need different responses:
#
#   pending  — registered; the domain's super-admin has not granted delegation,
#              or we have not proved it yet. Impersonation refused.
#   active   — a token was fetched for this subject and the grant is proven.
#   revoked  — deliberately switched off. Impersonation refused, row kept.
#              A TERMINAL state as far as any automatic path is concerned:
#              nothing reactivates it, and #reinstate! returns it only to
#              `pending`, which still has to prove delegation again.
#   severed  — the relationship is OVER (an acquisition, a client leaving).
#              Final: nothing reinstates it, not even #reinstate!. A severed
#              workspace comes back only as a new registration after the row is
#              purged, so "we cut them off" can never be undone by a typo.
class WorkspaceAccount < ApplicationRecord
  STATUSES = %w[pending active revoked severed].freeze

  # The two states in which nothing may be probed, flipped, or impersonated.
  SHUT = %w[revoked severed].freeze

  # Raised when something tries to ACTIVATE a revoked row. Never rescued into a
  # verdict — a caller reaching this has a bug, and a quiet no-op it ignores is
  # how the kill switch would come undone a second time.
  class Revoked < StandardError; end

  # The house convention: every Workspace we are given access to carries a
  # `team@` user, and that user is the one we act as.
  DEFAULT_LOCAL_PART = "team".freeze

  has_many :knowledge_sources, dependent: :nullify
  has_many :workspace_mailboxes, dependent: :restrict_with_exception

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
  validate :severed_is_final

  before_validation :normalize

  scope :active, -> { where(status: "active") }

  def self.default_subject_for(domain) = "#{DEFAULT_LOCAL_PART}@#{domain.to_s.strip.downcase}"

  # What an impersonation is FOR. The Google grant cannot tell these apart — one
  # key holds Drive and Gmail scopes for every address — so the purpose is the
  # boundary, checked here before any authorizer is built:
  #
  #   :workspace — the workspace's own subject only (team@). Drive walks and the
  #                domain-level check run as this.
  #   :mail      — the subject OR an allow-listed mailbox. Drafting, and reading
  #                the one thread a draft answers, run as this.
  #
  # So a mailbox row (alex@) opens that address's MAIL and never its Drive.
  PURPOSES = %i[workspace mail].freeze

  # The one question Credentials asks before impersonating anyone. Defaults to
  # the NARROW purpose, so a caller that forgets to say what it is for gets the
  # workspace subject only.
  def self.impersonatable?(subject, purpose: :workspace)
    raise ArgumentError, "unknown purpose #{purpose.inspect} (#{PURPOSES.join(', ')})" unless PURPOSES.include?(purpose)

    return true if active.exists?(subject: subject.to_s.strip.downcase)

    purpose == :mail && WorkspaceMailbox.impersonatable?(subject)
  end

  # Registered at all — the gate #probe applies, so a check can prove a pending
  # address without ever sweeping a domain for reachable users.
  def self.registered_address?(address)
    exists?(subject: address.to_s.strip.downcase) ||
      WorkspaceMailbox.exists?(address: WorkspaceMailbox.normalize_address(address))
  end

  def active? = status == "active"

  def shut? = SHUT.include?(status)

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
    if status == "severed"
      raise Revoked, "#{domain} is severed — the relationship is over and impersonation stays refused for good."
    end
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
    raise Revoked, "#{domain} is severed — already past revoked, and it stays that way." if status == "severed"

    self.notes = [ notes.presence, "#{Date.current.iso8601} revoked: #{reason}" ].compact.join("\n") if reason.present?
    update!(status: "revoked")
  end

  # The ONLY way back from revoked — and it does not restore access. The row
  # returns to `pending`, which is still refused, and the grant has to be proven
  # again before anything may impersonate the subject. So undoing a kill switch
  # takes a human naming the domain AND a live grant: two deliberate acts,
  # neither of which any sweep can perform on its own.
  def reinstate!
    raise ArgumentError, "#{domain} is severed — final, so it cannot be reinstated" if status == "severed"
    raise ArgumentError, "#{domain} is #{status}, not revoked — nothing to reinstate" unless status == "revoked"

    update!(status: "pending", delegation_verified_at: nil, last_check_error: nil)
  end

  # The end of the relationship. Any status -> severed, final. Every mailbox in
  # the workspace is shut with it, because WorkspaceMailbox.impersonatable?
  # requires an ACTIVE workspace.
  #
  # Like revoke!, this is the LOCAL half. The acquisition handoff runs in order:
  # export the rows, the client deletes our client id from their delegation page,
  # `workspace:check_severed` must then report CUT (Google answers
  # unauthorized_client), and only then is the row severed — so the record says
  # "cut" only after Google agrees. (`workspace:check` is not the proof: it skips
  # shut rows without probing them.)
  def sever!(reason)
    raise ArgumentError, "severing needs a reason — it is final and the notes are the record" if reason.blank?

    self.notes = [ notes.presence, "#{Date.current.iso8601} severed: #{reason}" ].compact.join("\n")
    update!(status: "severed")
  end

  # NOT an error state on its own. `unauthorized_client` is what a brand-new
  # grant looks like while it propagates — and also what a grant placed in the
  # WRONG Workspace looks like forever, which is why the reason is recorded
  # rather than reduced to a boolean.
  def mark_unverified!(reason)
    update!(status: (shut? ? status : "pending"),
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

  # Every write path refuses to move a severed row — this is the backstop that
  # holds even for a path that forgot to (update_column still bypasses it, as it
  # bypasses every validation).
  def severed_is_final
    return unless status_changed? && status_was == "severed"

    errors.add(:status, "is severed, which is final — it cannot become #{status}")
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
