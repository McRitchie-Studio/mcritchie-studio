require "test_helper"

# [integration] /packages and /packages/stack — the marketing cards and the full
# stack behind them, both public, both rendered from config/workspace_packages.yml,
# linked both ways. The admin-only SOP map lives on the full-stack page.
class PackagesControllerTest < ActionDispatch::IntegrationTest
  BOOKING = "https://calendar.app.google/enterprise-test".freeze

  def card(key) = "[data-test='package-card'][data-package='#{key}']"
  def cta(key) = "#{card(key)} [data-test='package-cta']"

  def log_in_admin
    admin = User.find_by(role: "admin") || User.create!(email: "packages-admin@example.com", name: "Packages Admin", role: "admin")
    log_in_as(admin)
  end

  # --- /packages ------------------------------------------------------------

  test "anyone sees four cards with prices, without signing in" do
    get packages_path

    assert_response :success
    assert_equal %w[vibe pro growth enterprise], css_select("[data-test='package-card']").map { |c| c["data-package"] }
    assert_select "#{card('vibe')} [data-test='price-free']", text: /Free/
    assert_select "#{card('pro')} [data-test='price-monthly']", text: %r{\$100\s*/month}
    assert_select "#{card('growth')} [data-test='price-monthly']", text: %r{\$500\s*/month}
    assert_select "#{card('growth')} [data-test='price-annual']", text: /\$450.*\$5,400 billed annually/m
    assert_select "#{card('enterprise')} [data-test='price-custom']", text: /Custom/
    assert_select "#{card('enterprise')} [data-test='price-monthly']", count: 0
    assert_select "[data-test='billing-toggle']", text: /save 10%/
  end

  test "each card leads with its promise and its highlights, Growth featured" do
    get packages_path

    assert_select "#{card('vibe')} [data-test='package-tagline']", text: /you\.mcritchie\.studio/
    WorkspacePackage.all.each do |package|
      assert_select "#{card(package.key)} [data-test='package-highlight']", package.highlights.size
    end
    assert_select "#{card('growth')}[data-featured='true'] [data-test='featured-badge']", text: /Most popular/
    assert_select "#{card('vibe')} [data-test='includes-previous']", 0
    assert_select "#{card('pro')} [data-test='includes-previous']", text: /Everything in Vibe, plus/
  end

  test "Vibe builds; Pro and Growth open the booking popup on /schedule" do
    get packages_path

    assert_select "#{cta('vibe')}[href='/build'][data-cta-target='build']", text: "Build your app"
    %w[pro growth].each do |key|
      assert_select "#{cta(key)}[href='/schedule'][data-booking-popup='true'][data-cta-target='schedule']"
    end
    assert_select "dialog[data-booking-dialog]", 1, "the popup the schedule CTAs open must be on the page"
  end

  test "Enterprise Book a call falls back to the studio's booking popup while no URL is configured" do
    get packages_path

    assert_select "#{cta('enterprise')}[href='/schedule'][data-booking-popup='true']", text: "Book a call"
    assert_select "#{cta('enterprise')}[target]", 0, "the fallback stays on the page in the popup"
  end

  test "Enterprise Book a call opens the configured Google Calendar page in a new tab" do
    WorkspacePackage.stub(:enterprise_booking_url, BOOKING) do
      get packages_path
    end

    assert_select "#{cta('enterprise')}[href='#{BOOKING}'][target='_blank'][rel='noopener'][data-cta-target='enterprise-booking']",
                  text: "Book a call"
    assert_select "#{cta('enterprise')}[data-booking-popup]", 0
    assert_select "#{cta('growth')}[href='/schedule']", 1, "only Enterprise takes the enterprise URL"
  end

  test "the billing toggle tells assistive tech which option is selected" do
    get packages_path

    assert_select "[data-test='billing-monthly'][aria-pressed='true']"
    assert_select "[data-test='billing-annual'][aria-pressed='false']"
    assert_includes response.body, %q(:aria-pressed="annual ? 'true' : 'false'"),
      "the pressed state must follow the toggle, not stay at its server-rendered value"
  end

  test "the marketing page links the full stack, and names no SOP or client" do
    get packages_path

    assert_select "a[data-test='full-stack-link'][href='/packages/stack']", text: /See the full stack for every tier/
    assert_select "[data-test='sop-map']", 0
    %w[website-launch workspace-signup domain-dns Cyvasse].each do |internal|
      assert_no_match(/#{internal}/, response.body, "#{internal} is internal — customers see only the offer")
    end
  end

  test "the sidebar links the packages page" do
    get packages_path

    assert_select "a[href='/packages']"
  end

  # --- /packages/stack ------------------------------------------------------

  test "the full stack is public: every row, grouped by category, one cell per tier" do
    get packages_stack_path

    assert_response :success
    assert_select "a[data-test='back-to-packages'][href='/packages']"
    assert_equal %w[vibe pro growth enterprise], css_select("[data-test='stack-tier-header']").map { |th| th["data-package"] }
    assert_equal WorkspacePackage.features_by_category.map(&:first),
                 css_select("[data-test='stack-category']").map { |tbody| tbody["data-category"] }
    assert_select "[data-test='stack-row']", WorkspacePackage.features.size
    css_select("[data-test='stack-row']").each do |row|
      assert_equal 4, row.css("[data-test='stack-cell']").size, "#{row['data-feature']} must have a cell per tier"
    end
    assert_select "[data-test='stack-legend']", text: /Included.*Not included.*Coming soon.*Add-on/m
  end

  test "values read across the row, with a check or a dash where nothing is quantified" do
    get packages_stack_path

    row = "[data-test='stack-row'][data-feature='server']"
    assert_equal [ "Eco dyno (sleeps when idle)", "Basic dyno", "Basic web + worker", "Sized to need" ],
                 css_select("#{row} [data-test='stack-cell']").map { |td| td.text.strip }
    assert_select "[data-feature='realtime-updates'] [data-test='stack-cell'][data-package='vibe']", text: "—"
    assert_select "[data-feature='realtime-updates'] [data-test='stack-cell'][data-package='pro']", text: "✓"
  end

  test "rows carry their software logos, and planned rows say Coming soon" do
    get packages_stack_path

    assert_select "[data-feature='file-storage'] [data-test='stack-software'] img[data-software='cloudflare']"
    assert_select "[data-feature='database'] img[data-software='postgres'][alt='Postgres']"
    assert_select "[data-feature='email-marketing'] img[data-software='zerobounce']"
    assert_select "[data-feature='social-posting'][data-status='planned'] [data-test='coming-soon']"
    assert_select "[data-feature='custom-connectors'] [data-test='coming-soon']"
    assert_select "[data-feature='server'] [data-test='coming-soon']", 0
  end

  test "the matrix scrolls inside its own box with a sticky tier header" do
    get packages_stack_path

    assert_select "[data-test='stack-matrix-scroll'].pkg-matrix-wrap table.pkg-matrix"
    assert_includes response.body, ".pkg-matrix thead th { position: sticky; top: 0;"
    assert_includes response.body, "var(--pin-stack-bottom, 0px)", "the desktop header sticks under the pinned navbar"
  end

  test "the full stack carries the same CTAs" do
    get packages_stack_path

    assert_select "tfoot [data-test='package-cta'][data-cta-action='build'][href='/build']"
    assert_select "tfoot [data-test='package-cta'][data-cta-action='enterprise_booking'][href='/schedule']"
  end

  test "the SOP map is hidden from customers" do
    get packages_stack_path

    assert_select "[data-test='sop-map']", 0
  end

  test "admins see every feature mapped to its SOP, the comps, and the master SOP" do
    log_in_admin

    get packages_stack_path

    assert_select "[data-test='sop-map-master'][href='/docs/agents/steffon/sops/workspace-launch']"
    %w[website-launch workspace-signup domain-dns workspace-provision bucket-provision].each do |sop|
      assert_select "[data-test='sop-map-row'][data-sop='#{sop}'] a[href='/docs/agents/steffon/sops/#{sop}']"
    end
    assert_select "[data-test='sop-map-comps']", text: /Pro — Cyvasse/
  end
end
