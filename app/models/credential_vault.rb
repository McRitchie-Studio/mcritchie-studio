# One 1Password vault, recorded — which client workspace it serves, which lane
# reads it, and the icon it wears in the 1Password app. The vault's contents
# are CredentialRecord rows; the secrets themselves never leave 1Password.
#
# Keyed by `slug`, the vault's name in 1Password ("industries-agents"). The
# client is the WorkspaceAccount whose domain matches `workspace_domain`; the
# column is a plain string so a vault can be recorded before its workspace is
# registered, and the association simply reads nil until then.
class CredentialVault < ApplicationRecord
  ENTITIES = %w[studio industries turf-monster commercial-welding family].freeze
  LANES = %w[agents admin applications human].freeze
  STATUSES = %w[active reserved retired].freeze

  has_many :credential_records, foreign_key: :credential_vault_slug, primary_key: :slug,
                                dependent: :restrict_with_exception, inverse_of: :credential_vault
  belongs_to :workspace_account, foreign_key: :workspace_domain, primary_key: :domain, optional: true

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true
  validates :entity, inclusion: { in: ENTITIES }
  validates :lane, inclusion: { in: LANES }
  validates :status, inclusion: { in: STATUSES }
  validate :icon_scope_is_configured

  scope :ordered, -> { order(:entity, :lane, :slug) }

  # The icon asset path for image_tag, or nil when this scope has not been
  # rendered yet — the page then says so rather than showing a broken image.
  def icon_asset = icon_scope.present? ? WorkspaceIconConfig.asset("1password", icon_scope) : nil

  def workspace_name = icon_workspace&.fetch("name", nil) || entity.titleize

  def icon_workspace
    return nil if icon_scope.blank?

    WorkspaceIconConfig.workspaces[icon_scope]
  end

  private

  # A scope that is not in config/workspace_icons.yml can never be rendered, so
  # naming one is a typo, not a plan.
  def icon_scope_is_configured
    return if icon_scope.blank? || WorkspaceIconConfig.workspaces.key?(icon_scope)

    errors.add(:icon_scope, "#{icon_scope.inspect} is not a workspace in config/workspace_icons.yml")
  end
end
