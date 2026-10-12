require "test_helper"

# [unit] WorkspacePackage — config/workspace_packages.yml is the one place
# package contents live, shaped as feature ROWS so the full-stack page can
# compare the tiers on the same line. The suite holds it to the SOP files on
# disk (a row that names an SOP must name one that exists), to the honesty rules
# the tier design was approved with on 2026-09-30, and to the 2026-10-12 ladder:
# Vibe, Builder, Pro and Team as cards, Enterprise as a "Talk to us" line.
class WorkspacePackageTest < ActiveSupport::TestCase
  TIERS = %w[vibe builder pro team enterprise].freeze

  def feature(name) = WorkspacePackage.features.find { |f| f.name == name } || flunk("no feature #{name}")

  test "[unit] four priced tiers load as cards in ladder order, plus the Enterprise talk-to-us line" do
    assert_equal %w[vibe builder pro team], WorkspacePackage.cards.map(&:key)
    assert WorkspacePackage.cards.all?(&:priced?), "every card carries a price"
    line = WorkspacePackage.talk_to_us
    assert_equal "enterprise", line.key
    refute line.card?
    assert_match(/Need more apps, white label or custom connectors\? Talk to us/, line.tagline)
    assert_equal({ "label" => "Book a call", "action" => "enterprise_booking" }, line.cta)
    assert_includes WorkspacePackage.keys, "enterprise", "Enterprise keeps its key for the clients stored on it"
    refute_includes WorkspacePackage.keys, "growth", "Growth split into Pro and Team on 2026-10-12"
  end

  test "five tiers load in ladder order, and each includes everything below it" do
    assert_equal TIERS, WorkspacePackage.all.map(&:key)

    TIERS.each_cons(2) do |lower, upper|
      below = WorkspacePackage.find(lower).features.map(&:name)
      above = WorkspacePackage.find(upper).features.map(&:name)
      assert_empty below - above, "#{upper} must include everything #{lower} does"
      assert_operator above.size, :>, below.size, "#{upper} must add something over #{lower}"
    end
  end

  test "[unit] prices: Vibe free, Builder $100, Pro $500, Team $1,500, Enterprise custom; 10% off billed annually" do
    vibe, builder, pro, team, enterprise = TIERS.map { |key| WorkspacePackage.find(key) }

    assert vibe.free?
    assert_nil vibe.annual_price, "a free tier has no annual bill to discount"
    assert_equal 10, WorkspacePackage.annual_discount_percent
    assert_equal [ 100, 1080, 90 ], [ builder.price_monthly, builder.annual_price, builder.annual_monthly_equivalent ]
    assert_equal [ 500, 5400, 450 ], [ pro.price_monthly, pro.annual_price, pro.annual_monthly_equivalent ]
    assert_equal [ 1500, 16_200, 1350 ], [ team.price_monthly, team.annual_price, team.annual_monthly_equivalent ]
    refute enterprise.priced?
    assert_equal "Custom", enterprise.price_label
    assert_nil enterprise.annual_price
  end

  test "the server row reads across: Eco, Basic, Basic web + worker, sized to need" do
    server = feature("Server")

    assert_equal [ "Eco dyno (sleeps when idle)", "Basic dyno", "Basic web + worker", "Basic web + worker", "Sized to need" ],
                 TIERS.map { |key| server.value_for(key) }
    assert server.varies?
    refute feature("HTTPS and deploys").varies?, "a row every tier shares identically is not highlighted"
  end

  test "an omitted value means not included: Vibe has no database, Builder no Google Workspace" do
    refute feature("Database").included_in?(:vibe)
    assert_nil feature("Database").value_for(:vibe)
    refute feature("Google Workspace").included_in?(:builder)
    assert_equal "2 seats included", feature("Google Workspace").value_for(:pro)
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
    assert_equal [ "team" ], WorkspacePackage.all.select(&:featured?).map(&:key), "exactly one card is featured"
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
    %w[application domain platform marketing service add_ons].each do |key|
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
    refute connectors.included_in?(:team)
    WorkspacePackage.features.each do |f|
      refute_match(/instagram/i, "#{f.name} #{f.blurb} #{f.values.values.join(' ')}", "Instagram posting does not exist")
      refute_includes f.display_software, "instagram", "#{f.name} may not show Instagram"
    end
  end

  test "payments, crypto and AI are Enterprise add-ons that only show their software" do
    [ "Payments", "Crypto and wallets", "AI features" ].each do |name|
      add_on = feature(name)
      assert_equal "Add-on", add_on.value_for(:enterprise), name
      TIERS.first(4).each { |key| refute add_on.included_in?(key), "#{name} is not in #{key}" }
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
    builder = WorkspacePackage.find(:builder).software_keys
    assert_includes builder, "postgres"
    assert_includes builder, "redis", "Builder's realtime updates run on Redis"
    pro = WorkspacePackage.find(:pro).software_keys
    %w[google redis sentry 1password resend cloudflare].each { |key| assert_includes pro, key }
    refute_includes pro, "zerobounce", "email marketing is a Team row"
    team = WorkspacePackage.find(:team).software_keys
    assert_includes team, "zerobounce"
    refute_includes team, "x", "planned social posting puts no X in a stack"

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

  test "every feature has an icon; a brand icon is a software key with a rendered mark" do
    WorkspacePackage.features.each do |f|
      assert f.icon.present?, "#{f.name} has no icon"
      next unless f.brand?

      assert WorkspaceIconConfig.brand(f.brand), "#{f.brand} has no brand mark; run bin/workspace-icon --tiles"
    end
    every = WorkspacePackage.features.flat_map(&:display_software).uniq
    every.each { |key| assert WorkspaceIconConfig.brand(key), "#{key} has no brand mark; run bin/workspace-icon --tiles" }
  end

  test "a row about one brand's product leads with that brand; generic rows stay neutral" do
    {
      "Server" => "heroku", "Error alerts" => "sentry", "Database" => "postgres",
      "Cache and job queue" => "redis", "App email from your domain" => "resend",
      "Google Workspace" => "google", "File storage" => "cloudflare", "Password vault" => "1password"
    }.each { |name, brand| assert_equal brand, feature(name).brand, name }
    [ "Custom app", "Web address", "Hosting mode", "Changes after launch", "Support", "Realtime updates", "Social posting" ].each do |name|
      refute feature(name).brand?, "#{name} is no single brand's product"
    end
  end

  test "the strip shows every other brand on the row, never the lead twice" do
    assert_equal %w[github rails], feature("Custom app").strip_brands, "the app leads with its own mark, so both logos strip"
    assert_empty feature("Server").strip_brands
    assert_equal %w[zerobounce], feature("Email marketing").strip_brands
    assert_equal %w[x tiktok], feature("Social posting").strip_brands
    assert_equal %w[egnyte slack], feature("Custom connectors").strip_brands
    assert_equal %w[anthropic openai], feature("AI features").strip_brands
  end

  test "a row names its brand on a card only from its brand_from tier, and a planned row names none" do
    address = feature("Web address")
    assert_empty address.card_brands("vibe"), "Vibe's address is a mcritchie.studio subdomain"
    assert_equal %w[squarespace], address.card_brands("builder")
    assert_equal %w[squarespace], address.card_brands("enterprise")
    assert_equal %w[github rails], feature("Custom app").card_brands("vibe"), "no brand_from: every tier names it"
    assert_empty feature("Custom connectors").card_brands("enterprise"), "a planned row is a promise"
    assert feature("Custom connectors").planned?
  end

  test "a card's Powered by row adds only what that tier adds, and never a planned brand" do
    vibe, builder, pro, team, enterprise = TIERS.map { |key| WorkspacePackage.find(key) }

    assert_equal %w[github rails heroku], vibe.card_brands
    assert_equal %w[postgres redis cloudflare squarespace resend], builder.card_brands(vibe)
    assert_equal %w[google sentry 1password], pro.card_brands(builder)
    assert_equal %w[zerobounce], team.card_brands(pro)
    assert_equal %w[stripe coinbase solana squads anthropic openai], enterprise.card_brands(team)
    refute_includes vibe.brand_keys, "squarespace", "Vibe's address is a subdomain, not a Squarespace domain"
    %w[x tiktok egnyte slack].each { |key| refute_includes enterprise.brand_keys, key, "#{key} rides a planned row" }
  end

  test "[unit] the talk-to-us line names Enterprise's add-ons as add-ons, and reads CMMC/ITAR as on request" do
    enterprise = WorkspacePackage.talk_to_us

    assert_equal %w[stripe coinbase solana squads anthropic openai], enterprise.add_on_brands
    WorkspacePackage.cards.each { |card| assert_empty card.add_on_brands, "#{card.key} sells no add-ons" }
    assert_equal "CMMC/ITAR review on request", feature("Credential rotation").value_for(:enterprise)
    assert_includes enterprise.highlights, "CMMC/ITAR compliance review, available on request"
    every = WorkspacePackage.all.flat_map(&:highlights) + WorkspacePackage.features.flat_map { |f| f.values.values.grep(String) }
    every.grep(/CMMC|ITAR/).each { |text| assert_match(/on request/, text, "CMMC/ITAR is offered, not delivered: #{text}") }
  end

  test "[unit] Builder carries Redis for its realtime updates" do
    assert_equal "Redis mini", feature("Cache and job queue").value_for(:builder)
    assert feature("Realtime updates").included_in?(:builder)
    refute feature("Cache and job queue").included_in?(:vibe)
  end

  test "[unit] Pro is Growth's platform; Team adds the marketing rows, funnel generation planned" do
    marketing = WorkspacePackage.features.select { |f| f.category == "marketing" }.map(&:name)
    assert_equal [ "Marketing strategy", "Content sprints", "Funnel generation", "Email marketing", "Launch warm-up", "Social posting" ], marketing
    marketing.each do |name|
      refute feature(name).included_in?(:pro), "#{name} is a Team row"
      assert feature(name).included_in?(:team), name
    end
    [ "Error alerts", "Google Workspace", "Agentic email drafting", "Knowledge base", "Password vault",
      "Dedicated browser profile", "Credential rotation", "Cloudflare DNS" ].each do |name|
      assert feature(name).included_in?(:pro), "#{name} is a Pro row"
    end

    funnel = feature("Funnel generation")
    assert funnel.planned?, "no SOP builds a funnel yet"
    assert_nil funnel.sop
    assert_match(/landing page.*lead capture.*email sequence.*measured/m, funnel.blurb)

    review = feature("Architecture and roadmap review")
    assert_equal "builtin", review.status
    assert_equal [ nil, nil, "Monthly", "Monthly", "Monthly" ], TIERS.map { |key| review.value_for(key) }
  end

  test "[unit] build requests read 4 a month on Pro and 6 a month on Team" do
    changes = feature("Changes after launch")

    assert_equal "4 build requests a month", changes.value_for(:pro)
    assert_equal "6 build requests a month", changes.value_for(:team)
    assert WorkspacePackage.find(:pro).highlights.any? { |h| h.start_with?("4 build requests a month") }
    assert WorkspacePackage.find(:team).highlights.any? { |h| h.start_with?("6 build requests a month") }
  end

  test "[unit] six groups, each paid step unlocking one: Custom app, Web address and Google Workspace lead theirs" do
    groups = WorkspacePackage.features_by_category

    assert_equal %w[application domain platform marketing service add_ons], groups.map(&:first)
    assert_equal %w[Application Domain Platform Marketing Service], groups.map { |g| g[1] }.first(5)
    assert_equal "Talk to us", WorkspacePackage.categories["add_ons"]
    leads = groups.to_h { |key, _, rows| [ key, rows.first.name ] }
    assert_equal({ "application" => "Custom app", "domain" => "Web address", "platform" => "Google Workspace",
                   "marketing" => "Marketing strategy", "service" => "Changes after launch", "add_ons" => "Custom connectors" }, leads)
    assert_equal [ "Web address", "Fast, protected domain" ], groups.assoc("domain").last.first(2).map(&:name)
    assert_equal({ "domain" => "builder", "platform" => "pro", "marketing" => "team" },
                 %w[application domain platform marketing service add_ons].to_h { |k| [ k, WorkspacePackage.category_from(k)&.key ] }.compact)
    # Marketing is Team's alone. Platform holds Hosting mode, whose lower tiers
    # read "McRitchie Studio hosted"; every other Platform row starts at Pro.
    groups.assoc("platform").last.reject { |row| row.name == "Hosting mode" }.each { |row| refute row.included_in?(:builder), row.name }
    groups.assoc("marketing").last.each { |row| refute row.included_in?(:pro), row.name }
    assert_equal "domain", feature("Web address").glyph, "the domain leads with the drawn globe mark"
    assert_equal %w[squarespace], feature("Web address").strip_brands, "the registrar stays in the strip"
    assert_equal "google", feature("Google Workspace").brand
    assert_equal [ nil, nil, "2 seats included", "2 seats included", "Custom" ],
                 TIERS.map { |key| feature("Google Workspace").value_for(key) }
    app = feature("Custom app")
    assert_equal "app", app.glyph, "the app leads with the drawn custom-app mark, not the GitHub logo"
    refute app.brand?
    assert_includes WorkspacePackage::GLYPHS, app.glyph
    assert_nil feature("Server").glyph
  end

  test "[unit] the web address reads three domain levels across the tiers" do
    address = feature("Web address")

    assert_equal [ "yourname.mcritchie.studio", "www.yourname.com", "yourname.com + www.yourname.com",
                   "yourname.com + www.yourname.com", "Multiple domains" ], TIERS.map { |key| address.value_for(key) }
    assert_equal "Your app's address, from our subdomain up to your own domain.", address.blurb,
                 "one short line: the cells already show the steps"
    assert_includes WorkspacePackage.find(:builder).highlights, "Your app at www.yourname.com, your own domain"
    assert_includes WorkspacePackage.find(:pro).highlights, "Your domain on Cloudflare, managed for you"
  end

  test "[unit] Pro sells the Cloudflare move: managed by us from Pro up, an honest free-plan promise" do
    row = feature("Fast, protected domain")

    assert_equal "cloudflare", row.brand
    assert_equal [ nil, nil, "Managed by us", "Managed by us", "Managed by us" ], TIERS.map { |key| row.value_for(key) }
    assert row.live?
    assert_equal [ "domain-dns", "Cloudflare DNS — Pro and above", "Approve the move once" ], [ row.sop, row.section, row.you_do ]
    assert_equal %w[cloudflare], row.software_keys(:pro)
    refute_match(/uptime|never goes down|100%|99/i, row.blurb, "no uptime promise")
    refute_includes WorkspacePackage.find(:pro).card_brands(WorkspacePackage.find(:builder)), "cloudflare",
                    "Builder already names Cloudflare for its R2 storage, so Pro adds no second chip"
  end

  test "[unit] taglines carry the 2026-10-12 promises" do
    assert_match(/fractional CTO/, WorkspacePackage.find(:pro).tagline)
    assert_match(/founding team: a CTO and a CMO/, WorkspacePackage.find(:team).tagline)
  end

  test "[unit] Cloudflare DNS is a live Pro-and-up row, led by the Cloudflare logo, delivered by domain-dns" do
    dns = feature(WorkspacePackage::CLOUDFLARE_DNS)

    assert_equal "domain", dns.category
    assert_equal "cloudflare", dns.brand, "the row leads with the Cloudflare logo"
    assert dns.live?, "mcritchie.studio and turfmonster.media already run on it"
    assert_equal "domain-dns", dns.sop
    assert_equal "Cloudflare DNS — Pro and above", dns.section
    assert_equal %w[pro team enterprise], TIERS.select { |key| dns.included_in?(key) }
    assert_equal "Bare domain + edge redirects", dns.value_for(:pro)
    assert_equal %w[cloudflare], dns.software_keys(:pro)
    assert_match(/bare domain/i, dns.blurb)
    assert_match(/redirect at Cloudflare's edge/, dns.blurb)
    assert_match(/agents manage every record by API/, dns.blurb)
  end

  test "[unit] the Turnstile bot check is promised honestly: planned, Coming soon, in no stack" do
    bot = feature("Bot check")

    assert bot.planned?, "no app wires Turnstile yet"
    assert_nil bot.sop
    assert_equal "cloudflare", bot.brand
    assert_equal %w[pro team enterprise], TIERS.select { |key| bot.included_in?(key) }
    assert_empty bot.card_brands("pro"), "a planned row names no brand on a card"
    refute bot.spotlight?
  end

  test "[unit] a card spotlights a delivered spotlight row from the tier that includes it" do
    TIERS.each do |key|
      names = WorkspacePackage.find(key).spotlight_features.map(&:name)
      expected = %w[pro team enterprise].include?(key) ? [ WorkspacePackage::CLOUDFLARE_DNS ] : []
      assert_equal expected, names, key
    end
    planned = WorkspacePackage::Feature.new(name: "Later", status: "planned", spotlight: "soon", values: {})
    refute planned.spotlight?, "a planned row is never spotlit"
  end
end
