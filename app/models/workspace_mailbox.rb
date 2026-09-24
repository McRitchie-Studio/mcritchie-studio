# One address inside a registered workspace that this system may draft as.
#
# WorkspaceAccount allows ONE address per domain (its `subject`). Drafting needs
# more — alex@ in every client domain, and later each admin's own address — so
# the allow-list gains named children here instead of loosening the
# one-row-per-domain rule.
#
# A mailbox is impersonatable only when BOTH halves say so:
#
#   * the mailbox is `active` — its own address was proven with a real token, and
#   * its workspace is `active` — so revoking or severing a workspace shuts every
#     mailbox in it at once, with no second switch to forget.
#
# Statuses mirror WorkspaceAccount's: pending → active → revoked, and a revoked
# mailbox never comes back on its own.
class WorkspaceMailbox < ApplicationRecord
  STATUSES = %w[pending active revoked].freeze

  belongs_to :workspace_account
  has_many :mailbox_drafts, dependent: :restrict_with_exception

  validates :address, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validate :address_belongs_to_workspace_domain

  before_validation :normalize

  scope :active, -> { where(status: "active") }

  def self.normalize_address(address) = address.to_s.strip.downcase

  # The question Workspace::Credentials asks for any address that is not a
  # workspace's own subject.
  def self.impersonatable?(address)
    active.joins(:workspace_account)
          .where(workspace_accounts: { status: "active" })
          .exists?(address: normalize_address(address))
  end

  def domain = address.to_s.split("@", 2).last

  def active? = status == "active"

  # Proven: a token was issued for THIS address. A revoked mailbox is never
  # resurrected by a check — the same asymmetry WorkspaceAccount#mark_verified!
  # keeps, for the same reason.
  def mark_verified!(at: Time.current)
    raise WorkspaceAccount::Revoked, "#{address} is revoked — drafting as it stays refused." if status == "revoked"

    update!(status: "active", verified_at: at, last_check_error: nil)
  end

  def mark_unverified!(reason)
    update!(status: (status == "revoked" ? "revoked" : "pending"), last_check_error: reason.to_s[0, 250])
  end

  def revoke!(reason = nil)
    self.notes = [ notes.presence, "#{Date.current.iso8601} revoked: #{reason}" ].compact.join("\n") if reason.present?
    update!(status: "revoked")
  end

  private

  def normalize
    self.address = self.class.normalize_address(address).presence
  end

  # The cross-tenant mistake again, closed the same way WorkspaceAccount closes
  # it: a mailbox can only ever name an address in its own workspace's domain.
  def address_belongs_to_workspace_domain
    return if address.blank? || workspace_account.nil?

    unless address.count("@") == 1 && !address.start_with?("@")
      errors.add(:address, "must be a single email address (got #{address})")
      return
    end
    return if address.end_with?("@#{workspace_account.domain}")

    errors.add(:address, "must be an address in #{workspace_account.domain} (got #{address})")
  end
end
