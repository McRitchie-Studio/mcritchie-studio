# One credential, recorded — NOT stored. The row says what an item in a
# 1Password vault is, who consumes it and what its scope permits, so the
# census can be read and joined to clients without opening a vault. There is
# no value column, and there must never be one.
#
# The secret-shape check below is a tripwire, not a guarantee: it refuses the
# token shapes we know (1Password, GitHub, Anthropic/OpenAI, AWS, Slack, PEM
# keys, Stripe, Heroku, a key in a URL's query) in every text column, because
# the likeliest way a secret lands here is a note pasted from the wrong window.
# An unknown shape passes it.
class CredentialRecord < ApplicationRecord
  STATUSES = %w[filed empty retired missing].freeze
  CATEGORIES = [ "API Credential", "Login", "Password", "Document", "Crypto Wallet", "Secure Note" ].freeze

  SECRET_SHAPES = {
    "1Password service-account token" => /\bops_[A-Za-z0-9_-]{20,}/,
    "GitHub token" => /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/,
    "API secret key" => /\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}/,
    "AWS access key id" => /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    "Slack token" => /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
    "private key" => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    "Stripe key" => /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/,
    "Stripe webhook secret" => /\bwhsec_[A-Za-z0-9]{16,}/,
    "Heroku token" => /\bHRKU-[A-Za-z0-9_-]{20,}/,
    "credential in a URL" => /[?&](?:api[-_]?key|key|token|secret|access_token)=[^&\s]{8,}/i
  }.freeze

  TEXT_COLUMNS = %w[title service url used_by scope_summary notes].freeze

  def self.service_label(service) = WorkspaceIconConfig.software_name(service)

  # <service>.<entity>.<lane> — the credential-filing convention.
  CONVENTION = /\A[a-z0-9-]+\.[a-z0-9-]+\.(?:agents|admin|applications)\z/

  belongs_to :credential_vault, foreign_key: :credential_vault_slug, primary_key: :slug, inverse_of: :credential_records

  validates :title, presence: true, uniqueness: { scope: :credential_vault_slug }
  validates :service, presence: true
  validates :entity, inclusion: { in: CredentialVault::ENTITIES }, allow_blank: true
  validate :service_is_configured
  validates :status, inclusion: { in: STATUSES }
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true
  validate :holds_no_secret

  scope :ordered, -> { order(:status, :title) }

  # Filed under the convention, or a grandfathered name (credential-filing §2).
  def conventional? = title.match?(CONVENTION)

  def live? = %w[filed empty].include?(status)

  # The client this credential serves: its own `entity` when set (the Turf
  # Monster keys live in the Studio vault), else its vault's.
  def served_entity = entity.presence || credential_vault&.entity

  private

  # Every service is a row with an icon, so it must be a software in
  # config/workspace_icons.yml — a typo would otherwise open an iconless row.
  def service_is_configured
    return if service.blank? || WorkspaceIconConfig.softwares.key?(service)

    errors.add(:service, "#{service.inspect} is not a software in config/workspace_icons.yml")
  end

  def holds_no_secret
    TEXT_COLUMNS.each do |column|
      value = self[column].to_s
      SECRET_SHAPES.each do |label, shape|
        next unless value.match?(shape)

        errors.add(column, "looks like a #{label} — a record names a credential, it never holds one")
      end
    end
  end
end
