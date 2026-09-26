require "test_helper"

# [unit] StackClient — a client's stack is DERIVED (tier software + live
# credential records + extras), and each software's hosting is its config
# default unless this client overrides it. The page draws exactly this.
class StackClientTest < ActiveSupport::TestCase
  def client(**attrs)
    StackClient.new({ slug: "commercial-welding", name: "Commercial Welding", tier: "workspace" }.merge(attrs))
  end

  test "the tier must be a package key or internal" do
    assert client.valid?
    assert client(tier: "internal").valid?
    refute client(tier: "basic").valid?, "Basic was retired for Workspace on 2026-09-25"
  end

  test "the slug must be a workspace in config/workspace_icons.yml" do
    refute client(slug: "atlantis").valid?
  end

  test "a tier's software comes first, in config order" do
    keys = client.software_keys([])

    assert_equal WorkspacePackage.find(:workspace).software_keys.sort, keys.sort
    order = WorkspaceIconConfig.softwares.keys
    assert_equal keys.sort_by { |k| order.index(k) }, keys, "the strip reads in config order"
  end

  test "live records add their software; missing and retired ones do not" do
    vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    live = CredentialRecord.new(credential_vault: vault, title: "turf.stripe", service: "stripe", entity: "commercial-welding")
    never_filed = CredentialRecord.new(credential_vault: vault, title: "x.api", service: "x", status: "missing")
    retired = CredentialRecord.new(credential_vault: vault, title: "old.coinbase", service: "coinbase", status: "retired")

    keys = client.software_keys([ live, never_filed, retired ])

    assert_includes keys, "stripe"
    refute_includes keys, "x", "an item that was never filed is not software the client has"
    refute_includes keys, "coinbase"
  end

  test "extra_software is added, and must be configured" do
    assert_includes client(extra_software: [ "discord" ]).software_keys([]), "discord"
    refute client(extra_software: [ "myspace" ]).valid?
  end

  test "an internal client has no tier software, only what its records bring" do
    assert_empty client(tier: "internal").software_keys([])
  end

  test "hosting defaults from config: Google is ours on every client, X is theirs" do
    c = client

    assert c.ms_hosted?("google"), "Google carries the Studio chest on every client"
    refute c.ms_hosted?("x")
    assert_equal "workspace_icons/google/studio.png", c.icon_for("google")
    assert_equal "workspace_icons/software/x.png", c.icon_for("x")
  end

  test "a white-label client overrides hosting per software" do
    c = client(hosting: { "heroku" => "own" })

    refute c.ms_hosted?("heroku")
    assert_equal "workspace_icons/software/heroku.png", c.icon_for("heroku"), "white label draws the plain logo"
    refute client(hosting: { "heroku" => "theirs" }).valid?
    refute client(hosting: { "myspace" => "ms" }).valid?
  end

  test "resend mode and google users are checked" do
    assert client(resend_mode: "white_label", google_users: 2).valid?
    refute client(resend_mode: "sendgrid").valid?
    refute client(google_users: -1).valid?
  end

  test "the client's Google workspace joins by domain" do
    c = client(domain: "commercialwelding.llc")
    c.save!
    assert_nil c.workspace_account

    account = WorkspaceAccount.create!(domain: "commercialwelding.llc")
    assert_equal account, c.reload.workspace_account
  end
end
