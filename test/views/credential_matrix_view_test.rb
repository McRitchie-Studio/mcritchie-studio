# frozen_string_literal: true

require "test_helper"

# [component] The /credentials matrix in isolation: software down the side (in
# config order), entity across the top, and each cell the badged icon for that
# pair — dimmed when nothing live stands behind it, with the 1Password items in
# its tooltip rather than on the page.
#
# Google is the one row with a second source: an entity with a Google domain
# gets a cell from its delegation grant even with no item of its own, because
# one shared service-account key acts in every registered domain.
#
# Named ...ViewTest so it can never collide with the controller test's class.
class CredentialMatrixViewTest < ActionView::TestCase
  setup do
    studio = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    @records = [
      CredentialRecord.create!(credential_vault: studio, title: "heroku.studio.agents", service: "heroku"),
      CredentialRecord.create!(credential_vault: studio, title: "heroku.studio.extra", service: "heroku"),
      CredentialRecord.create!(credential_vault: studio, title: "anthropic", service: "anthropic", status: "missing"),
      CredentialRecord.create!(credential_vault: studio, title: "solana.turf.system", service: "solana", entity: "turf-monster"),
      CredentialRecord.create!(credential_vault: studio, title: "gmail.studio.agents", service: "google")
    ]
    WorkspaceAccount.create!(domain: "mcritchie.studio", status: "active")
    WorkspaceAccount.create!(domain: "commercialwelding.llc") # pending

    order = WorkspaceIconConfig.softwares.keys
    @workspaces = WorkspaceIconConfig.workspaces
    @entities = CredentialVault::ENTITIES
    @services = @records.map(&:service).uniq.sort_by { |s| order.index(s) }
    @matrix = @records.group_by(&:service).transform_values { |rows| rows.group_by(&:served_entity) }
    @domains = WorkspaceIconConfig.domains
    @workspace_accounts = WorkspaceAccount.where(domain: @domains.values).index_by(&:domain)
  end

  def cell(service, entity) = "[data-test='matrix-software'][data-service='#{service}'] [data-test='matrix-cell'][data-entity='#{entity}']"

  test "one column per entity, each headed by its 1Password vault icon or a No badge placeholder" do
    render template: "credential_vaults/index"

    assert_select "[data-test='matrix-entity']", CredentialVault::ENTITIES.size
    assert_select "[data-test='matrix-entity'][data-entity='studio'] [data-test='entity-icon']", 1
    assert_select "[data-test='matrix-entity'][data-entity='family'] [data-test='entity-icon-missing']", 1
  end

  test "rows follow the config's software order, not the alphabet" do
    render template: "credential_vaults/index"

    rows = css_select("[data-test='matrix-software']").map { |tr| tr["data-service"] }
    assert_equal %w[google anthropic heroku solana], rows, "Google is pinned near the top by config order"
  end

  test "a cell is one icon with its items in the tooltip, and counts them when there are several" do
    render template: "credential_vaults/index"

    icon = css_select("#{cell('heroku', 'studio')} [data-test='matrix-icon']").first
    assert icon, "no heroku x studio icon"
    assert_includes icon["title"], "heroku.studio.agents (agents)"
    assert_equal "true", icon["data-live"]
    assert_select "#{cell('heroku', 'studio')} [data-test='record-count']", text: "2 items"
    assert_select "#{cell('heroku', 'studio')} img[src*='workspace_icons/heroku/studio']", 1
  end

  test "a record sits under the client it serves, not the vault it lives in" do
    render template: "credential_vaults/index"

    assert_select "#{cell('solana', 'turf-monster')} [data-test='matrix-icon']", 1
    assert_select "#{cell('solana', 'studio')} [data-test='matrix-icon']", 0
  end

  test "a cell with nothing live behind it is dimmed" do
    render template: "credential_vaults/index"

    icon = css_select("#{cell('anthropic', 'studio')} [data-test='matrix-icon']").first
    assert_equal "false", icon["data-live"]
    assert_select "#{cell('anthropic', 'studio')} img.grayscale", 1
  end

  test "Google shows every entity with a domain, carrying its delegation grant" do
    render template: "credential_vaults/index"

    studio = css_select("#{cell('google', 'studio')} [data-test='matrix-icon']").first
    assert_equal "active", studio["data-delegation"]
    assert_includes studio["title"], "mcritchie.studio"
    assert_includes studio["title"], "gmail.studio.agents"

    welding = css_select("#{cell('google', 'commercial-welding')} [data-test='matrix-icon']").first
    assert welding, "an entity with a domain gets a Google cell even with no item of its own"
    assert_equal "pending", welding["data-delegation"]
    assert_equal "false", welding["data-live"], "a grant that is not active is dimmed"

    assert_select "#{cell('google', 'industries')} [data-test='matrix-icon'][data-delegation='not registered']", 1
    assert_select "#{cell('google', 'family')} [data-test='matrix-icon']", 0, "family has no Google workspace"
  end
end
