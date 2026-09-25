# The credential census as a matrix: software down the side, entity across the
# top, each column headed by that entity's 1Password vault icon. A cell lists
# the records of that software's credentials in that entity's vaults.
# Records only — nothing here can read or show a secret value.
class CredentialVaultsController < ApplicationController
  before_action :require_admin

  def index
    @workspaces = OnepassIconConfig.workspaces
    @entities = CredentialVault::ENTITIES
    records = CredentialRecord.includes(:credential_vault).order(:title).to_a
    @services = records.map(&:service).uniq.sort_by { |service| CredentialRecord.service_label(service).downcase }
    @matrix = records.group_by(&:service).transform_values { |rows| rows.group_by { |r| r.credential_vault.entity } }
  end
end
