require "test_helper"

# [component] /packages — the four tiers as swim lanes on one row grid, the
# difference visible in the row, and the admin-only SOP map beneath.
class PackagesControllerTest < ActionDispatch::IntegrationTest
  def lane(key) = "[data-test='package-card'][data-package='#{key}']"

  test "anyone sees all four lanes with prices, without signing in" do
    get packages_path

    assert_response :success
    assert_select "#{lane('launch')} [data-test='price-free']", text: /Free/
    assert_select "#{lane('launch')} [data-test='price-monthly']", count: 0
    assert_select "#{lane('host')} [data-test='price-monthly']", text: %r{\$100\s*/month}
    assert_select "#{lane('workspace')} [data-test='price-monthly']", text: %r{\$200\s*/month}
    assert_select "#{lane('agentic')} [data-test='price-monthly']", text: %r{\$500\s*/month}
    assert_select "#{lane('agentic')} [data-test='price-annual']", text: /\$450.*\$5,400 billed annually/m
    assert_select "[data-test='billing-toggle']", text: /save 10%/
    assert_no_match(/Everything in Basic, plus/, response.body, "the lanes compare row by row instead")
  end

  test "every lane carries the SAME rows in the same order, so they line up" do
    get packages_path

    rows = %w[launch host workspace agentic].map do |key|
      css_select("#{lane(key)} [data-test='feature-row']").map { |row| row["data-feature"] }
    end
    assert_equal 1, rows.uniq.size, "the lanes must list identical rows"
    assert_equal WorkspacePackage.features.size, rows.first.size
  end

  test "the difference is in the row: 2 users vs 10 users, Google logo in both" do
    get packages_path

    assert_select "#{lane('workspace')} [data-feature='google-workspace']", text: /2 users/ do
      assert_select "svg[aria-label='Google']"
    end
    assert_select "#{lane('agentic')} [data-feature='google-workspace']", text: /10 users/
    assert_select "#{lane('agentic')} [data-feature='production-hosting'] [data-test='feature-value']", text: /more power \+ database space/
  end

  test "an Agentic-only feature reads 'Not included' in the lower lanes" do
    get packages_path

    assert_select "#{lane('workspace')} [data-feature='social-media-outreach'][data-included='false']", text: /Not included/
    assert_select "#{lane('agentic')} [data-feature='social-media-outreach'][data-included='true']" do
      assert_select "svg[aria-label='TikTok']"
      assert_select "svg[aria-label='Instagram']"
    end
    assert_select "#{lane('agentic')} [data-feature='team-drafting-access']", text: /Coming soon/
    assert_select "#{lane('workspace')} [data-feature='app-email-from-your-domain'][data-included='true']", text: /Coming soon/
  end

  test "a brand logo shows only where the package gets that product" do
    get packages_path

    assert_select "#{lane('workspace')} [data-feature='social-media-outreach']" do
      assert_select "svg[aria-label='TikTok']", count: 0
      assert_select "svg[aria-label='Instagram']", count: 0
      assert_select "[data-test='not-included-mark']"
    end
    assert_select "#{lane('agentic')} [data-feature='social-media-outreach'] [data-test='not-included-mark']", count: 0
  end

  test "the TikTok logo sits on its own dark tile, so it shows on the light theme" do
    get packages_path

    assert_select "#{lane('agentic')} svg[aria-label='TikTok'] rect[fill='#000000']"
  end

  test "the billing toggle tells assistive tech which option is selected" do
    get packages_path

    assert_select "[data-test='billing-monthly'][aria-pressed='true']"
    assert_select "[data-test='billing-annual'][aria-pressed='false']"
    assert_includes response.body, %q(:aria-pressed="annual ? 'true' : 'false'"),
      "the pressed state must follow the toggle, not stay at its server-rendered value"
  end

  test "the SOP map is hidden from customers" do
    get packages_path

    assert_select "[data-test='sop-map']", count: 0
    %w[website-launch workspace-signup domain-dns].each do |sop|
      assert_no_match(/#{sop}/, response.body, "SOP slugs are internal — customers see only the offer")
    end
  end

  test "admins see every feature mapped to its SOP, with the master SOP linked" do
    admin = User.find_by(role: "admin") || User.create!(email: "packages-admin@example.com", name: "Packages Admin", role: "admin")
    log_in_as(admin)

    get packages_path

    assert_select "[data-test='sop-map-master'][href='/docs/agents/steffon/sops/workspace-launch']"
    %w[website-launch workspace-signup domain-dns workspace-provision].each do |sop|
      assert_select "[data-test='sop-map-row'][data-sop='#{sop}'] a[href='/docs/agents/steffon/sops/#{sop}']"
    end
  end

  test "the sidebar links the packages page" do
    get packages_path

    assert_select "a[href='/packages']"
  end
end
