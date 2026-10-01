require "test_helper"

# [component] PackagesHelper — every card CTA resolves to a live link. The one
# that depends on config (Enterprise's booking URL) must work both while the URL
# is blank and once it is filled.
class PackagesHelperTest < ActionView::TestCase
  BOOKING = "https://calendar.app.google/enterprise-test".freeze

  def link_for(key, **options) = Nokogiri::HTML.fragment(package_cta_link(WorkspacePackage.find(key), **options)).at("a")

  test "Vibe builds an app" do
    link = link_for(:vibe, class: "btn")

    assert_equal "/build", link["href"]
    assert_equal "Build your app", link.text
    assert_equal "btn", link["class"]
    assert_nil link["data-booking-popup"]
  end

  test "Pro and Growth open the booking popup, with /schedule as the no-script fallback" do
    %i[pro growth].each do |key|
      link = link_for(key)
      assert_equal "/schedule", link["href"], key
      assert_equal "true", link["data-booking-popup"], key
      assert_nil link["target"], "#{key}: the popup keeps the visitor on the page"
    end
  end

  test "Enterprise falls back to the booking popup while the URL is blank — never a dead link" do
    WorkspacePackage.stub(:enterprise_booking_url, nil) do
      link = link_for(:enterprise)
      assert_equal "/schedule", link["href"]
      assert_equal "true", link["data-booking-popup"]
      assert_equal "Book a call", link.text
    end
  end

  test "Enterprise opens the configured booking page in a new tab once it is set" do
    WorkspacePackage.stub(:enterprise_booking_url, BOOKING) do
      link = link_for(:enterprise)
      assert_equal BOOKING, link["href"]
      assert_equal "_blank", link["target"]
      assert_equal "noopener", link["rel"]
      assert_nil link["data-booking-popup"]
    end
  end

  test "an unknown action still links somewhere live" do
    package = WorkspacePackage.new({ "key" => "x", "name" => "X", "cta" => { "label" => "Go", "action" => "nope" } })
    link = Nokogiri::HTML.fragment(package_cta_link(package)).at("a")

    assert_equal "/schedule", link["href"]
  end

  test "a matrix cell reads a check, a dash or the value" do
    assert_equal "✓", package_cell_text(true)
    assert_equal "—", package_cell_text(nil)
    assert_equal "Basic dyno", package_cell_text("Basic dyno")
  end
end
