require "test_helper"

# [unit] WorkspacePackage — config/workspace_packages.yml is the one place
# package contents live, shaped as feature ROWS so the page can compare Basic
# and Pro on the same line. The suite holds it to the SOP files on disk: a row
# that names an SOP must name one that exists, or the /packages SOP map links
# nowhere and workspace-launch runs a step it cannot read.
class WorkspacePackageTest < ActiveSupport::TestCase
  def feature(name) = WorkspacePackage.features.find { |f| f.name == name } || flunk("no feature #{name}")

  test "Basic and Pro load, and Pro includes every Basic feature" do
    basic = WorkspacePackage.find(:basic)
    pro = WorkspacePackage.find(:pro)

    assert_equal %w[basic pro], WorkspacePackage.all.map(&:key)
    assert_empty basic.features.map(&:name) - pro.features.map(&:name), "Pro must include everything Basic does"
    assert_operator pro.features.size, :>, basic.features.size
  end

  test "the difference reads across the row: 2 users vs 10 users" do
    workspace = feature("Google Workspace")

    assert_equal "2 users", workspace.value_for(:basic)
    assert_equal "10 users", workspace.value_for(:pro)
    assert workspace.varies?
    refute feature("Password vault").varies?, "a row both packages share identically is not highlighted"
  end

  test "both packages get a hosted domain; Pro's has more power and database space" do
    hosted = feature("Hosted domain")

    assert_match(/1 domain/, hosted.value_for(:basic))
    assert_match(/1 domain/, hosted.value_for(:pro))
    assert_match(/database/, hosted.value_for(:pro))
  end

  test "an omitted package value means not included" do
    storage = feature("File storage")

    refute storage.included_in?(:basic)
    assert storage.included_in?(:pro)
    assert_nil storage.value_for(:basic)
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

  test "the Basic features are the ones workspace-launch walks" do
    launch = Rails.root.join("docs/agents/#{WorkspacePackage.sop_paths.fetch('workspace-launch')}.md").read
    WorkspacePackage.find(:basic).features.select(&:live?).each do |f|
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

  test "prices: $100 and $500 a month, 10% off billed annually" do
    basic = WorkspacePackage.find(:basic)
    pro = WorkspacePackage.find(:pro)

    assert_equal 10, WorkspacePackage.annual_discount_percent
    assert_equal [ 100, 1080, 90 ], [ basic.price_monthly, basic.annual_price, basic.annual_monthly_equivalent ]
    assert_equal [ 500, 5400, 450 ], [ pro.price_monthly, pro.annual_price, pro.annual_monthly_equivalent ]
  end
end
