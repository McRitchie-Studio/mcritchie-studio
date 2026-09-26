require "test_helper"

# [unit] WorkspacePackage — config/workspace_packages.yml is the one place
# package contents live, shaped as feature ROWS so the page can compare the four
# tiers on the same line. The suite holds it to the SOP files on disk: a row
# that names an SOP must name one that exists, or the /packages SOP map links
# nowhere and workspace-launch runs a step it cannot read.
class WorkspacePackageTest < ActiveSupport::TestCase
  TIERS = %w[launch host workspace agentic].freeze

  def feature(name) = WorkspacePackage.features.find { |f| f.name == name } || flunk("no feature #{name}")

  test "four tiers load in ladder order, and each includes everything below it" do
    assert_equal TIERS, WorkspacePackage.all.map(&:key)

    TIERS.each_cons(2) do |lower, upper|
      below = WorkspacePackage.find(lower).features.map(&:name)
      above = WorkspacePackage.find(upper).features.map(&:name)
      assert_empty below - above, "#{upper} must include everything #{lower} does"
      assert_operator above.size, :>, below.size, "#{upper} must add something over #{lower}"
    end
  end

  test "the difference reads across the row: 2 users vs 10 users" do
    workspace = feature("Google Workspace")

    assert_equal "2 users", workspace.value_for(:workspace)
    assert_equal "10 users", workspace.value_for(:agentic)
    assert workspace.varies?
    refute feature("App template and pipeline").varies?, "a row every tier shares identically is not highlighted"
  end

  test "hosting starts at Host, and the domain at Workspace" do
    hosting = feature("Production hosting")
    domain = feature("Hosted domain")

    refute hosting.included_in?(:launch), "Launch runs locally — the first hosting bill is Host's"
    assert_match(/1 app/, hosting.value_for(:host))
    assert_match(/database/, hosting.value_for(:agentic))
    assert_equal "website-launch", hosting.sop

    refute domain.included_in?(:host)
    assert_match(/1 domain/, domain.value_for(:workspace))
  end

  test "Resend is part of Workspace and up, not an add-on" do
    resend = feature("App email from your domain")

    refute resend.included_in?(:host)
    assert resend.included_in?(:workspace)
    assert resend.included_in?(:agentic)
    assert_equal [ "resend" ], resend.software_keys
  end

  test "an omitted package value means not included" do
    storage = feature("File storage")

    refute storage.included_in?(:workspace)
    assert storage.included_in?(:agentic)
    assert_nil storage.value_for(:workspace)
  end

  test "a tier's software is every software its features provision, and only config keys" do
    assert_equal %w[github], WorkspacePackage.find(:launch).software_keys
    assert_equal %w[github heroku], WorkspacePackage.find(:host).software_keys
    agentic = WorkspacePackage.find(:agentic).software_keys
    assert_includes agentic, "google"
    assert_includes agentic, "instagram"
    assert_empty agentic - WorkspaceIconConfig.softwares.keys, "every software key must have an icon in config/workspace_icons.yml"
  end

  test "every live feature names an SOP that exists on disk" do
    WorkspacePackage.features.select(&:live?).each do |f|
      assert f.sop.present?, "#{f.name} is live but names no SOP"
      assert f.doc_path, "#{f.name} names #{f.sop}, which is not a registered SOP file"
      assert Rails.root.join("docs/agents/#{f.doc_path}.md").exist?
    end
  end

  test "statuses are live or planned, and a planned feature claims no SOP yet" do
    WorkspacePackage.features.each do |f|
      assert_includes WorkspacePackage::STATUSES, f.status, "#{f.name} has status #{f.status.inspect}"
      assert_nil f.doc_path, "#{f.name} is planned but links an SOP" unless f.live?
    end
  end

  test "a section named on a feature is a real heading in its SOP" do
    WorkspacePackage.features.select(&:section).each do |f|
      text = Rails.root.join("docs/agents/#{f.doc_path}.md").read
      assert_match(/^##+ #{Regexp.escape(f.section)}/, text, "#{f.sop} has no heading '#{f.section}'")
    end
  end

  test "the Workspace tier's live features are the ones workspace-launch walks" do
    launch = Rails.root.join("docs/agents/#{WorkspacePackage.sop_paths.fetch('workspace-launch')}.md").read
    WorkspacePackage.find(:workspace).features.select(&:live?).each do |f|
      assert_includes launch, "`#{f.sop}`", "workspace-launch does not walk #{f.sop}"
    end
  end

  test "every feature has an icon, and each logo key has a partial" do
    WorkspacePackage.features.each do |f|
      assert f.icon.present?, "#{f.name} has no icon"
      f.logos.each do |logo|
        assert Rails.root.join("app/views/packages/logos/_#{logo}.html.erb").exist?, "no logo partial for #{logo}"
      end
    end
    assert_equal %w[tiktok instagram], feature("Social media outreach").logos
  end

  test "prices: Launch free, then $100, $200 and $500 a month, 10% off billed annually" do
    launch, host, workspace, agentic = TIERS.map { |key| WorkspacePackage.find(key) }

    assert launch.free?
    assert_nil launch.annual_price, "a free tier has no annual bill to discount"
    assert_equal 10, WorkspacePackage.annual_discount_percent
    assert_equal [ 100, 1080, 90 ], [ host.price_monthly, host.annual_price, host.annual_monthly_equivalent ]
    assert_equal [ 200, 2160, 180 ], [ workspace.price_monthly, workspace.annual_price, workspace.annual_monthly_equivalent ]
    assert_equal [ 500, 5400, 450 ], [ agentic.price_monthly, agentic.annual_price, agentic.annual_monthly_equivalent ]
    refute host.free?
  end
end
