require "test_helper"

# [component] /packages — the public Basic vs Pro comparison, and the admin-only
# SOP map beneath it.
class PackagesControllerTest < ActionDispatch::IntegrationTest
  test "anyone can see both packages without signing in" do
    get packages_path

    assert_response :success
    assert_select "[data-test='package-card'][data-package='basic']"
    assert_select "[data-test='package-card'][data-package='pro']" do
      assert_select "p", text: /Everything in Basic, plus:/
    end
    assert_select "[data-test='package-price']", text: /Pricing coming soon/, count: 2
    assert_select "[data-test='package-item'][data-status='planned']", text: /Coming soon/
    # Branding: Google Workspace carries Google's logo and its seat count.
    assert_select "[data-test='package-item']", text: /Google Workspace/ do
      assert_select "svg[aria-label='Google']"
      assert_select "[data-test='package-item-detail']", text: "2 users"
    end
    assert_select "[data-test='package-item-detail']", text: "1 site"
  end

  test "the SOP map is hidden from customers" do
    get packages_path

    assert_select "[data-test='sop-map']", count: 0
    assert_no_match(/domain-purchase/, response.body, "SOP slugs are internal — customers see only the offer")
  end

  test "admins see every item mapped to its SOP, with the master SOP linked" do
    admin = User.find_by(role: "admin") || User.create!(email: "packages-admin@example.com", name: "Packages Admin", role: "admin")
    log_in_as(admin)

    get packages_path

    assert_select "[data-test='sop-map']"
    assert_select "[data-test='sop-map-master'][href='/docs/agents/steffon/sops/workspace-launch']"
    %w[domain-purchase workspace-signup domain-dns workspace-provision].each do |sop|
      assert_select "[data-test='sop-map-row'][data-sop='#{sop}'] a[href='/docs/agents/steffon/sops/#{sop}']"
    end
  end

  test "the sidebar links the packages page" do
    get packages_path

    assert_select "a[href='/packages']"
  end
end
