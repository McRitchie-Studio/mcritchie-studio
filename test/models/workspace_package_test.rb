require "test_helper"

# [unit] WorkspacePackage — config/workspace_packages.yml is the one place
# package contents live, shaped as feature ROWS so the full-stack page can
# compare the four tiers on the same line. The suite holds it to the SOP files
# on disk (a row that names an SOP must name one that exists) and to the honesty
# rules the tier design was approved with on 2026-09-30.
class WorkspacePackageTest < ActiveSupport::TestCase
  TIERS = %w[vibe pro growth enterprise].freeze

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

  test "prices: Vibe free, Pro $100, Growth $500, Enterprise custom; 10% off billed annually" do
    vibe, pro, growth, enterprise = TIERS.map { |key| WorkspacePackage.find(key) }

    assert vibe.free?
    assert_nil vibe.annual_price, "a free tier has no annual bill to discount"
    assert_equal 10, WorkspacePackage.annual_discount_percent
    assert_equal [ 100, 1080, 90 ], [ pro.price_monthly, pro.annual_price, pro.annual_monthly_equivalent ]
    assert_equal [ 500, 5400, 450 ], [ growth.price_monthly, growth.annual_price, growth.annual_monthly_equivalent ]
    refute enterprise.priced?
    assert_equal "Custom", enterprise.price_label
    assert_nil enterprise.annual_price
  end

  test "the server row reads across: Eco, Basic, Basic web + worker, sized to need" do
    server = feature("Server")

    assert_equal [ "Eco dyno (sleeps when idle)", "Basic dyno", "Basic web + worker", "Sized to need" ],
                 TIERS.map { |key| server.value_for(key) }
    assert server.varies?
    refute feature("HTTPS and deploys").varies?, "a row every tier shares identically is not highlighted"
  end

  test "an omitted value means not included: Vibe has no database, Pro no Google Workspace" do
    refute feature("Database").included_in?(:vibe)
    assert_nil feature("Database").value_for(:vibe)
    refute feature("Google Workspace").included_in?(:pro)
    assert_equal "2 seats included", feature("Google Workspace").value_for(:growth)
  end

  test "each package carries a card: a tagline, 4-6 highlights and a known CTA" do
    WorkspacePackage.all.each do |package|
      assert package.tagline.present?, "#{package.key} has no tagline"
      assert_includes 4..6, package.highlights.size, "#{package.key} must lead with 4-6 highlights"
      assert package.cta["label"].present?, "#{package.key} has no CTA label"
      assert_includes WorkspacePackage::CTA_ACTIONS, package.cta["action"], "#{package.key} CTA action"
      assert package.comp.present?, "#{package.key} names no comp client"
    end
    assert_equal "build", WorkspacePackage.find(:vibe).cta["action"]
    assert_equal "enterprise_booking", WorkspacePackage.find(:enterprise).cta["action"]
    assert_equal [ "growth" ], WorkspacePackage.all.select(&:featured?).map(&:key), "exactly one card is featured"
  end

  test "the enterprise booking URL is blank until supplied, and only an https URL counts" do
    assert_nil WorkspacePackage.enterprise_booking_url, "Mr. McRitchie has not supplied the URL yet"

    { "https://calendar.app.google/abc123" => "https://calendar.app.google/abc123",
      "  https://calendar.app.google/abc123 " => "https://calendar.app.google/abc123",
      "javascript:alert(1)" => nil, "/schedule" => nil, "http://example.com" => nil, "" => nil }.each do |raw, expected|
      WorkspacePackage.stub(:config, WorkspacePackage.config.merge("enterprise_booking_url" => raw)) do
        expected ? assert_equal(expected, WorkspacePackage.enterprise_booking_url, raw.inspect) : assert_nil(WorkspacePackage.enterprise_booking_url, raw.inspect)
      end
    end
  end

  test "every feature sits in a configured category, and the page groups them in category order" do
    categories = WorkspacePackage.categories.keys
    WorkspacePackage.features.each do |f|
      assert_includes categories, f.category, "#{f.name} has category #{f.category.inspect}"
    end

    groups = WorkspacePackage.features_by_category
    assert_equal categories.select { |key| groups.map(&:first).include?(key) }, groups.map(&:first)
    assert_equal WorkspacePackage.features.size, groups.sum { |_, _, rows| rows.size }
    %w[hosting data domain email auth storage marketing agents security connectors add_ons].each do |key|
      assert_includes groups.map(&:first), key
    end
  end

  test "honest status: what is not live in production reads as planned and provisions nothing" do
    social = feature("Social posting")
    connectors = feature("Custom connectors")

    assert social.planned?, "X/TikTok posting has no production keys"
    assert_empty social.software_keys, "a planned row puts nothing in a client's stack"
    assert_equal %w[x tiktok], social.display_software
    assert connectors.planned?, "Egnyte is not built"
    assert_equal "Scoped per client", connectors.value_for(:enterprise)
    refute connectors.included_in?(:growth)
    WorkspacePackage.features.each do |f|
      refute_match(/instagram/i, "#{f.name} #{f.blurb} #{f.values.values.join(' ')}", "Instagram posting does not exist")
      refute_includes f.display_software, "instagram", "#{f.name} may not show Instagram"
    end
  end

  test "payments, crypto and AI are Enterprise add-ons that only show their software" do
    [ "Payments", "Crypto and wallets", "AI features" ].each do |name|
      add_on = feature(name)
      assert_equal "Add-on", add_on.value_for(:enterprise), name
      TIERS.first(3).each { |key| refute add_on.included_in?(key), "#{name} is not in #{key}" }
      assert_empty add_on.software_keys, "#{name}: an add-on is recorded per client, not provisioned by the tier"
      assert add_on.display_software.any?, "#{name} shows its software on the full-stack page"
    end
  end

  test "file storage is Cloudflare R2, not the retired AWS key" do
    assert_equal %w[cloudflare], feature("File storage").software_keys
    refute_includes WorkspacePackage.find(:enterprise).software_keys, "aws"
  end

  test "a tier's software is every software its features provision, and only config keys" do
    assert_equal %w[github rails heroku], WorkspacePackage.find(:vibe).software_keys
    pro = WorkspacePackage.find(:pro).software_keys
    assert_includes pro, "postgres"
    refute_includes pro, "redis"
    growth = WorkspacePackage.find(:growth).software_keys
    %w[google redis sentry zerobounce 1password resend cloudflare].each { |key| assert_includes growth, key }
    refute_includes growth, "x", "planned social posting puts no X in a stack"

    every = WorkspacePackage.features.flat_map(&:display_software).uniq
    assert_empty every - WorkspaceIconConfig.softwares.keys, "every software key must have an icon in config/workspace_icons.yml"
    every.each { |key| assert WorkspaceIconConfig.tile(key), "#{key} has no tile; run bin/workspace-icon --tiles" }
  end

  test "statuses are live, builtin or planned; live rows name an SOP on disk, others name none" do
    WorkspacePackage.features.each do |f|
      assert_includes WorkspacePackage::STATUSES, f.status, "#{f.name} has status #{f.status.inspect}"
      if f.live?
        assert f.sop.present?, "#{f.name} is live but names no SOP"
        assert f.doc_path, "#{f.name} names #{f.sop}, which is not a registered SOP file"
        assert Rails.root.join("docs/agents/#{f.doc_path}.md").exist?
      else
        assert_nil f.sop, "#{f.name} is #{f.status} but names an SOP — mark it live"
      end
    end
  end

  test "a section named on a feature is a real heading in its SOP" do
    WorkspacePackage.features.select(&:section).each do |f|
      text = Rails.root.join("docs/agents/#{f.doc_path}.md").read
      assert_match(/^##+ #{Regexp.escape(f.section)}/, text, "#{f.sop} has no heading '#{f.section}'")
    end
  end

  test "every feature has an icon, and each logo key has a partial" do
    WorkspacePackage.features.each do |f|
      assert f.icon.present?, "#{f.name} has no icon"
      f.logos.each do |logo|
        assert Rails.root.join("app/views/packages/logos/_#{logo}.html.erb").exist?, "no logo partial for #{logo}"
      end
    end
    assert feature("Google Workspace").logo?
  end

  test "every legacy tier maps to a current tier" do
    assert_equal %w[launch host workspace agentic], WorkspacePackage::LEGACY_TIERS.keys
    assert_empty WorkspacePackage::LEGACY_TIERS.values - WorkspacePackage.keys
    assert_empty WorkspacePackage::LEGACY_TIERS.keys & WorkspacePackage.keys, "a legacy key may not be reused"
  end
end
