require "test_helper"

# [unit] CredentialVault — one 1Password vault, recorded: the client workspace
# it serves (joined by domain, so it can be recorded before the workspace is)
# and the icon scope it wears.
class CredentialVaultTest < ActiveSupport::TestCase
  def vault(**attrs)
    CredentialVault.new({ slug: "industries-agents", name: "Industries agents", entity: "industries", lane: "agents" }.merge(attrs))
  end

  test "a vault joins its client workspace by domain, and reads nil until that workspace exists" do
    v = vault(workspace_domain: "mason.test")
    v.save!
    assert_nil v.workspace_account

    account = WorkspaceAccount.create!(domain: "mason.test")
    assert_equal account, v.reload.workspace_account
  end

  test "the icon scope must be a workspace in config/workspace_icons.yml" do
    assert vault(icon_scope: "industries").valid?

    bad = vault(icon_scope: "atlantis")
    refute bad.valid?
    assert_match(/not a workspace/, bad.errors[:icon_scope].first)
  end

  test "icon_asset is the rendered 1Password icon, or nil when that scope has none" do
    assert_equal "workspace_icons/1password/studio.png", vault(icon_scope: "studio").icon_asset
    assert_nil vault(icon_scope: "family").icon_asset, "family has no badge, so nothing is rendered"
  end

  test "entity, lane and status are closed vocabularies" do
    refute vault(entity: "atlantis").valid?
    refute vault(lane: "personal").valid?
    refute vault(status: "gone").valid?
  end

  test "a vault with records cannot be deleted out from under them" do
    v = vault
    v.save!
    CredentialRecord.create!(credential_vault: v, title: "google.industries.agents", service: "google")

    assert_raises(ActiveRecord::DeleteRestrictionError) { v.destroy }
  end
end
