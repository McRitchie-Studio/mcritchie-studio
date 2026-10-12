require "test_helper"

# [component] PackagesHelper — every card CTA resolves to a live link. The one
# that depends on config (Enterprise's booking URL) must work both while the URL
# is blank and once it is filled.
class PackagesHelperTest < ActionView::TestCase
  # package_cta_link writes its booking links with the engine's
  # studio_booking_link. A controller's view has every helper; this test's view
  # has only the ones named here.
  include Studio::SiteFooterHelper

  BOOKING = "https://calendar.app.google/enterprise-test".freeze

  def link_for(key, **options) = Nokogiri::HTML.fragment(package_cta_link(WorkspacePackage.find(key), **options)).at("a")

  test "Vibe builds an app" do
    link = link_for(:vibe, class: "btn")

    assert_equal "/build", link["href"]
    assert_equal "Build your app", link.text
    assert_equal "btn", link["class"]
    assert_nil link["data-booking-popup"]
  end

  test "Builder, Pro and Team open the booking popup, with /schedule as the no-script fallback" do
    %i[builder pro team].each do |key|
      link = link_for(key)
      assert_equal "/schedule", link["href"], key
      assert_equal "true", link["data-booking-popup"], key
      assert_equal "true", link["data-studio-booking"], "#{key}: the engine's popup script answers only to its own marker"
      assert_equal "schedule", link["data-cta-target"], key
      assert_nil link["target"], "#{key}: the popup keeps the visitor on the page"
    end
  end

  test "Enterprise falls back to the booking popup while the URL is blank — never a dead link" do
    WorkspacePackage.stub(:enterprise_booking_url, nil) do
      link = link_for(:enterprise)
      assert_equal "/schedule", link["href"]
      assert_equal "true", link["data-booking-popup"]
      assert_equal "true", link["data-studio-booking"]
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

  test "[unit] a hostname value breaks only at its plus, never inside a hostname" do
    assert_equal [ [ "yourname.mcritchie.studio", true ] ], package_cell_segments("yourname.mcritchie.studio")
    assert_equal [ [ "yourname.com", true ], [ "www.yourname.com", true ] ], package_cell_segments("yourname.com + www.yourname.com")
    assert_equal [ [ "Basic web", false ], [ "worker", false ] ], package_cell_segments("Basic web + worker")
    assert_equal [ [ "Multiple domains", false ] ], package_cell_segments("Multiple domains")
  end

  test "[unit] a hostname wraps only after its first label, and only while a dot remains" do
    assert_equal "yourname.<wbr>mcritchie.studio", package_hostname("yourname.mcritchie.studio").to_s
    assert_equal "www.<wbr>yourname.com", package_hostname("www.yourname.com").to_s
    assert_equal "yourname.com", package_hostname("yourname.com").to_s
  end

  test "[unit] a tagline keeps its hostname on one line, trailing period outside" do
    html = package_tagline("A real app built by our agents, live at your-app.mcritchie.studio.").to_s
    assert_equal 'A real app built by our agents, live at <span class="whitespace-nowrap" data-test="tagline-host">your-app.mcritchie.studio</span>.', html
    assert_equal "Your founding team: a CTO and a CMO.", package_tagline("Your founding team: a CTO and a CMO.").to_s
  end

  test "a matrix cell reads a check, a dash or the value" do
    assert_equal "✓", package_cell_text(true)
    assert_equal "—", package_cell_text(nil)
    assert_equal "Basic dyno", package_cell_text("Basic dyno")
  end
end
