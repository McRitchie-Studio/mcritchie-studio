# The credential census as a matrix: software down the side, entity across the
# top, each column headed by that entity's 1Password vault icon. A cell lists
# the records of that software's credentials in that entity's vaults.
# Records only — nothing here can read or show a secret value.
class CredentialVaultsController < ApplicationController
  before_action :require_admin

  def index
    @workspaces = WorkspaceIconConfig.workspaces
    @entities = CredentialVault::ENTITIES
    records = CredentialRecord.includes(:credential_vault).order(:title).to_a
    # Rows follow config/workspace_icons.yml's software order, so the headline
    # accounts sit at the top by an edit to the config, not to this page.
    order = WorkspaceIconConfig.softwares.keys
    @services = records.map(&:service).uniq.sort_by { |service| [ order.index(service) || order.size, service ] }
    # Google access for a client is a delegation grant on its domain, read with
    # the one shared service-account key, so the Google row also shows each
    # entity's workspace and whether that grant is proven.
    @domains = WorkspaceIconConfig.domains
    @workspace_accounts = WorkspaceAccount.where(domain: @domains.values).index_by(&:domain)
    @matrix = records.group_by(&:service).transform_values { |rows| rows.group_by(&:served_entity) }
  end
end
