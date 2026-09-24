require "test_helper"

# [unit] WorkspacePackage — config/workspace_packages.yml is the one place
# package contents live, so the suite holds it to the SOP files on disk: an item
# that names an SOP must name one that exists, or the /packages SOP map links
# nowhere and workspace-launch runs a step it cannot read.
class WorkspacePackageTest < ActiveSupport::TestCase
  test "Basic and Pro load, and Pro includes everything in Basic first" do
    basic = WorkspacePackage.find(:basic)
    pro = WorkspacePackage.find(:pro)

    assert_equal %w[basic pro], WorkspacePackage.all.map(&:key)
    assert_equal "basic", pro.includes
    assert_equal basic.items.map(&:name), pro.items.first(basic.items.size).map(&:name)
    assert_operator pro.items.size, :>, basic.items.size
  end

  test "every live item names an SOP that exists on disk" do
    WorkspacePackage.all.flat_map(&:own_items).select(&:live?).each do |item|
      assert item.sop.present?, "#{item.name} is live but names no SOP"
      assert item.doc_path, "#{item.name} names #{item.sop}, which is not a registered SOP file"
      assert Rails.root.join("docs/agents/#{item.doc_path}.md").exist?
    end
  end

  test "statuses are live or planned, and a planned item claims no SOP yet" do
    WorkspacePackage.all.flat_map(&:own_items).each do |item|
      assert_includes WorkspacePackage::STATUSES, item.status, "#{item.name} has status #{item.status.inspect}"
      assert_nil item.doc_path, "#{item.name} is planned but links an SOP" unless item.live?
    end
  end

  test "a section named on an item is a real heading in its SOP" do
    WorkspacePackage.all.flat_map(&:own_items).select(&:section).each do |item|
      text = Rails.root.join("docs/agents/#{item.doc_path}.md").read
      assert_match(/^##+ #{Regexp.escape(item.section)}/, text, "#{item.sop} has no heading '#{item.section}'")
    end
  end

  test "the Basic steps are exactly the ones workspace-launch walks" do
    launch = Rails.root.join("docs/agents/#{WorkspacePackage.sop_paths.fetch('workspace-launch')}.md").read
    WorkspacePackage.find(:basic).own_items.select(&:live?).each do |item|
      assert_includes launch, "`#{item.sop}`", "workspace-launch does not walk #{item.sop}"
    end
  end

  test "every item has an icon, and a logo key has a partial to render" do
    WorkspacePackage.all.flat_map(&:own_items).each do |item|
      assert item.icon.present?, "#{item.name} has no icon"
      next unless item.logo?

      assert Rails.root.join("app/views/packages/logos/_#{item.icon}.html.erb").exist?, "no logo partial for #{item.icon}"
    end
  end
end
