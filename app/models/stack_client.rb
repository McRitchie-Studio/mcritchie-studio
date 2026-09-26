# One McRitchie Studio client as /stack shows it: the tier they are on, the
# software in their stack, which of it we host for them, and the two details
# the page leads with (Google users, Resend mode).
#
# A client's STACK is derived, not typed: the software its tier provisions
# (config/workspace_packages.yml `software:`), plus the software its credential
# records serve (credential_records served to this entity), plus any
# `extra_software`. Typing the list would drift the first time a tier or a
# record changed.
#
# HOSTING is per software: `ms` means it runs on McRitchie Studio's own account
# for this client (drawn with the Studio chest in the corner), `own` means the
# client's own account (drawn plain). The default comes from each software's
# `hosting:` in config/workspace_icons.yml; `hosting` here holds only this
# client's overrides — a white-label client is { "heroku" => "own", ... }.
class StackClient < ApplicationRecord
  # Studio and Industries are us: on the page, never on a price list.
  INTERNAL = "internal".freeze
  HOSTING_MODES = %w[ms own].freeze
  # ms: the client's sending domain on McRitchie Studio's Resend account.
  # white_label: the client's own Resend account.
  RESEND_MODES = %w[ms white_label].freeze

  belongs_to :workspace_account, foreign_key: :domain, primary_key: :domain, optional: true

  validates :slug, presence: true, uniqueness: true
  validates :name, presence: true
  validates :tier, inclusion: { in: ->(_) { WorkspacePackage.keys + [ INTERNAL ] } }
  validates :resend_mode, inclusion: { in: RESEND_MODES }, allow_blank: true
  validates :google_users, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :slug_is_a_configured_workspace
  validate :hosting_overrides_are_known
  validate :extra_software_is_configured

  scope :ordered, -> { order(:position, :name) }

  def internal? = tier == INTERNAL

  def package = internal? ? nil : WorkspacePackage.find(tier)

  def tier_name = internal? ? "Internal" : package&.name

  def records = CredentialRecord.includes(:credential_vault).select { |record| record.served_entity == slug }

  # Tier software, then record software, then extras — de-duplicated and put in
  # the config's software order, so every row reads left to right the same way.
  # A page drawing many clients passes each one's records in, preloaded once.
  def software_keys(served_records = records)
    # Only LIVE records put software in a stack: an item that was never filed
    # (missing) or was retired is not software the client has.
    live = served_records.select(&:live?).map(&:service)
    keys = Array(package&.software_keys) + live + Array(extra_software)
    order = WorkspaceIconConfig.softwares.keys
    keys.uniq.select { |key| order.include?(key) }.sort_by { |key| order.index(key) }
  end

  def hosting_for(software) = hosting[software.to_s].presence || WorkspaceIconConfig.default_hosting(software)

  def ms_hosted?(software) = hosting_for(software) == "ms"

  # MS-hosted: the software logo with the Studio chest in its corner. The
  # client's own account: the plain logo.
  def icon_for(software)
    ms_hosted?(software) ? WorkspaceIconConfig.asset(software, "studio") : WorkspaceIconConfig.tile(software)
  end

  def badge_icon = WorkspaceIconConfig.asset("1password", slug)

  private

  def slug_is_a_configured_workspace
    return if slug.blank? || WorkspaceIconConfig.workspaces.key?(slug)

    errors.add(:slug, "#{slug.inspect} is not a workspace in config/workspace_icons.yml")
  end

  def hosting_overrides_are_known
    unknown = hosting.keys - WorkspaceIconConfig.softwares.keys
    errors.add(:hosting, "names unknown software: #{unknown.join(', ')}") if unknown.any?
    bad = hosting.values - HOSTING_MODES
    errors.add(:hosting, "modes must be #{HOSTING_MODES.join(' or ')} (got #{bad.join(', ')})") if bad.any?
  end

  def extra_software_is_configured
    unknown = Array(extra_software) - WorkspaceIconConfig.softwares.keys
    errors.add(:extra_software, "names unknown software: #{unknown.join(', ')}") if unknown.any?
  end
end
