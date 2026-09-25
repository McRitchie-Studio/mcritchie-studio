# The credential census by client workspace: each workspace's 1Password vault
# icon, the vaults that wear it, and the records of what those vaults hold.
# Records only — nothing here can read or show a secret value.
class CredentialVaultsController < ApplicationController
  before_action :require_admin

  def index
    @workspaces = OnepassIconConfig.workspaces
    vaults = CredentialVault.ordered.includes(:credential_records, :workspace_account)
    @vaults_by_scope = vaults.group_by(&:icon_scope)
  end
end
