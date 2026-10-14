require "test_helper"

# [integration] /packages and /packages/stack — the marketing cards and the full
# stack behind them, both public, both rendered from config/workspace_packages.yml,
# linked both ways. The admin-only SOP map lives on the full-stack page.
class PackagesControllerTest < ActionDispatch::IntegrationTest
  BOOKING = "https://calendar.app.google/enterprise-test".freeze

  def card(key) = "[data-test='package-card'][data-package='#{key}']"
  def cta(key) = "#{card(key)} [data-test='package-cta']"

  # A matrix cell as text: a two-line product cell reads "product|metric".
  def cell_text(td)
    name = td.at_css("[data-test='stack-product-name']")
    name ? "#{name.text.strip}|#{td.at_css("[data-test='stack-product-metric']").text.strip}" : td.text.strip
  end
  TALK = "[data-test='talk-to-us'][data-package='enterprise']".freeze
  TALK_CTA = "#{TALK} [data-test='package-cta']".freeze

  def log_in_admin
    admin = User.find_by(role: "admin") || User.create!(email: "packages-admin@example.com", name: "Packages Admin", role: "admin")
    log_in_as(admin)
  end

  # --- /packages ------------------------------------------------------------

  test "[component] anyone sees four cards with prices, without signing in" do
    get packages_path

    assert_response :success
    assert_equal %w[vibe builder pro team], css_select("[data-test='package-card']").map { |c| c["data-package"] }
    assert_equal %w[Vibe Builder Pro Team], css_select("[data-test='package-card'] h2").map { |h| h.text.strip }
    assert_select "#{card('vibe')} [data-test='price-free']", text: /Free/
    assert_select "#{card('builder')} [data-test='price-monthly']", text: %r{\$100\s*/month}
    assert_select "#{card('pro')} [data-test='price-monthly']", text: %r{\$500\s*/month}
    assert_select "#{card('pro')} [data-test='price-annual']", text: /\$450.*\$5,400 billed annually/m
    assert_select "#{card('team')} [data-test='price-monthly']", text: %r{\$900\s*/month}
    assert_select "#{card('team')} [data-test='price-annual']", text: /\$810.*\$9,720 billed annually/m
    assert_select card("enterprise"), 0, "Enterprise is a Talk to us line, not a card"
    assert_select "[data-test='price-custom']", 0
    assert_select "[data-test='billing-toggle']", text: /save 10%/
  end

  test "[component] Enterprise is one Talk to us line under the cards, with a Book a call button" do
    get packages_path

    assert_select TALK, 1
    assert_operator response.body.rindex("data-test=\"package-card\""), :<, response.body.index("data-test=\"talk-to-us\""),
                    "the line sits under the cards"
    assert_select "#{TALK} [data-test='talk-to-us-question']", text: "Need more apps, white label or custom connectors? Talk to us."
    assert_select "#{TALK_CTA}[data-cta-action='enterprise_booking']", text: "Book a call"
    assert_select "#{TALK} [data-test='talk-to-us-highlight']", WorkspacePackage.find(:enterprise).highlights.size
    assert_select "#{TALK} [data-test='talk-to-us-highlight']", text: /CMMC\/ITAR compliance review, available on request/
    assert_select "#{TALK} [data-test='talk-to-us-add-ons']", text: /Add-ons, priced per contract/
    assert_equal %w[stripe coinbase solana squads anthropic openai],
                 css_select("#{TALK} [data-test='talk-to-us-add-ons'] [data-test='brand-logo']").map { |l| l["data-brand"] }
  end

  test "each card names the brands its tier adds, Vibe first as Powered by" do
    get packages_path

    assert_select "#{card('vibe')} [data-test='package-powered-by']", text: /Powered by/
    assert_equal %w[github rails heroku], css_select("#{card('vibe')} [data-test='brand-logo']").map { |l| l["data-brand"] }
    assert_select "#{card('builder')} [data-test='package-powered-by']", text: /Also powered by/
    assert_select "[data-test='package-powered-by']", text: /\AAdds\z/, count: 0
    assert_select "#{card('builder')} [data-test='brand-logo'][data-brand='redis']"
    assert_select "#{card('pro')} [data-test='brand-logo'][data-brand='1password']"
    assert_equal %w[zerobounce], css_select("#{card('team')} [data-test='package-powered-by'] [data-test='brand-logo']").map { |l| l["data-brand"] }
    assert_select "[data-test='package-card'] [data-test='brand-logo'][data-brand='openai']", 0, "add-ons are not a card's brands"
    assert_select "[data-test='package-card'] [data-test='brand-logo'][data-brand='egnyte']", 0
  end

  test "[component] each card lists grouped lines with status marks, one teaser of the next tier, Team featured" do
    get packages_path

    assert_select "#{card('vibe')} [data-test='package-tagline']", text: /your-app\.mcritchie\.studio/
    assert_select "#{card('pro')} [data-test='package-tagline']", text: /fractional CTO/
    assert_select "#{card('team')} [data-test='package-tagline']", text: /founding team: a CTO and a CMO/
    WorkspacePackage.cards.each do |package|
      assert_select "#{card(package.key)} [data-test='package-line']", package.card_lines.size
      assert_equal package.card_group_names,
                   css_select("#{card(package.key)} [data-test='package-line-group']").map { |g| g["data-group"] }
      assert_equal package.card_lines.map(&:key), css_select("#{card(package.key)} [data-test='package-line']").map { |l| l["data-lane"] }
    end
    assert_equal %w[Application Marketing Agents],
                 css_select("#{card('team')} [data-test='package-line-group']").map { |p| p.text.strip }
    assert_select "[data-test='package-line-group'][data-group='Platform']", 0, "Platform left the cards"
    assert_select "[data-test='package-highlight']", 0
    assert_select "[data-test='includes-previous']", 0
    assert_select "[data-test='package-spotlight']", 0, "the Cloudflare callout boxes are gone"
    # Every card spans the same tracks, so lanes share rows across the cards.
    spans = css_select("[data-test='package-card']").map { |c| c["style"] }
    assert_equal 1, spans.uniq.size
    assert_match(/grid-row: span 21/, spans.first)

    # Marks carry their words: never color alone.
    assert_select "#{card('builder')} [data-test='package-line'][data-status='included'] [data-test='line-mark'][data-mark='included'][role='img'][aria-label='Included']", 3
    team_marketing = %w[email_marketing content warmup funnels]
    { "vibe" => { "domain" => "Builder", "integrations" => "Pro", "vault" => "Pro" },
      "builder" => { "integrations" => "Pro", "vault" => "Pro", "social" => "Pro" }.merge(team_marketing.to_h { |k| [ k, "Team" ] }),
      "pro" => team_marketing.to_h { |k| [ k, "Team" ] }.merge("cmo" => "Team", "drafting" => "Team") }.each do |key, lanes|
      assert_equal lanes.keys, css_select("#{card(key)} [data-test='package-line'][data-status='missing']").map { |l| l["data-lane"] }, key
      lanes.each do |lane, tier|
        row = "#{card(key)} [data-test='package-line'][data-lane='#{lane}']"
        assert_select "#{row} [data-test='line-mark'][data-mark='missing'][aria-label='In #{tier}']", 1
        assert_select "#{row} [data-test='line-in-tier']", text: "(In #{tier})"
      end
    end
    vibe_domain = "#{card('vibe')} [data-test='package-line'][data-lane='domain']"
    assert_select "#{vibe_domain} [data-test='line-title']", text: /Custom Domain\s*\(In Builder\)/
    assert_select "#{vibe_domain} [data-test='line-sub']", text: "on your-app.mcritchie.studio"
    assert_select "[data-test='line-title']", text: /Web address/, count: 0
    assert_select "#{card('team')} [data-test='package-line'][data-status='missing']", 0
    soon = "#{card('team')} [data-test='package-line'][data-status='soon']"
    assert_select soon, 2
    assert_select "#{soon} [data-test='line-mark'][data-mark='soon'][aria-label='Coming soon']", 2
    assert_select "#{soon} [data-test='line-sub'] [data-test='coming-soon']", 2, "the tag sits on the subtext line"
    assert_select "#{soon} [data-test='line-title'] [data-test='coming-soon']", 0
    { "pro" => [ "Social Outreach", "posts you approve" ], "team" => [ "CMO-Managed Social", "strategy & posting" ] }.each do |key, (title, sub)|
      social = "#{card(key)} [data-test='package-line'][data-lane='social'][data-status='soon']"
      assert_select "#{social} [data-test='line-mark'][data-mark='soon']", 1, key
      assert_select "#{social} [data-test='line-title']", text: title
      assert_select "#{social} [data-test='line-sub']", text: /#{sub}\s*Coming soon/
    end
    assert_equal %w[social email_marketing content warmup funnels],
                 css_select("#{card('team')} [data-test='package-line']").map { |l| l["data-lane"] }[5, 5], "Social Outreach leads Marketing"
    assert_select "[data-test='line-title']", text: /Social posting/, count: 0
    assert_equal %w[cto cmo drafting], css_select("#{card('team')} [data-test='package-line-group'][data-group='Agents'] ~ [data-test='package-line']").map { |l| l["data-lane"] }.select { |k| %w[cto cmo drafting].include?(k) }
    assert_select "#{card('pro')} [data-test='package-line'][data-lane='drafting'][data-status='missing'] [data-test='line-in-tier']", text: "(In Team)"
    assert_select "#{soon} [data-mark='included']", 0

    %w[pro team].each do |key|
      app = "#{card(key)} [data-test='package-line'][data-lane='app']"
      assert_select "#{app} [data-test='line-title']", text: "CTO-Managed Web App"
      assert_select "#{app} [data-test='line-sub']", text: "Always-on CTO"
      integrations = "#{card(key)} [data-test='package-line'][data-lane='integrations'][data-status='included']"
      assert_select "#{integrations} [data-test='line-title'] a.underline[href='/integrations']", text: "Integrations"
      assert_select "#{integrations} [data-test='line-sub']", text: "Google Workspace, Discord & more"
    end
    assert_select "#{card('builder')} [data-test='package-line'][data-lane='app'] [data-test='line-title']", text: "Custom Web App"
    assert_select "#{card('builder')} [data-test='package-line'][data-lane='app'] [data-test='line-sub']", text: "several changes a month"
    assert_select "#{card('builder')} [data-test='package-line'][data-lane='integrations'][data-status='missing'] a", 0,
                  "a lane the tier lacks is not a link"
    assert_no_match(/build requests? a month|small changes after launch/, response.body)
    %w[pro team].each do |key|
      domain = "#{card(key)} [data-test='package-line'][data-lane='domain'][data-status='included']"
      assert_select "#{domain} [data-test='line-title']", text: "Premium Domain"
      assert_select "#{domain} [data-test='line-sub']", text: "best-in-class speed & security"
    end
    %w[pro team].each do |key|
      cto = "#{card(key)} [data-test='package-line'][data-lane='cto'][data-status='included']"
      assert_select "#{cto} [data-test='line-mark'][data-mark='included']"
      assert_select "#{cto} [data-test='line-sub']", text: "24-hour access & daily summaries"
    end
    assert_no_match(/monthly architecture review|daily report on application health/, response.body)
    builder_domain = "#{card('builder')} [data-test='package-line'][data-lane='domain']"
    assert_select "#{builder_domain} [data-test='line-title']", text: "Custom Domain"
    assert_select "#{builder_domain} [data-test='line-sub']", text: "www.your-app.com"
    assert_select "[data-test='line-title']", text: /Premium Domain/, count: 2
    assert_no_match(/Cloudflare/, css_select("[data-test='package-line']").text, "the cards sell the outcome; Cloudflare is the stack's detail")
    assert_select "[data-test='package-line'][data-lane='app_email'], [data-test='package-line'][data-lane='custom_email']", 0
    assert_select "#{card('pro')} [data-test='package-line'][data-lane='host_storage'] [data-test='line-title']", text: "Pro Host & Storage"
    assert_no_match(/you@your-app.com, 2 users/, response.body, "the Workspace lane became Integrations")
    assert_no_match(/yourname|yourcompany/, response.body)
    assert_no_match(/credit/i, css_select("[data-test='package-cards']").text)
    assert_select "#{card('team')}[data-featured='true'] [data-test='featured-badge']", text: /Most popular/
    assert_select "[data-test='featured-badge']", 1
  end

  test "Vibe builds; Builder, Pro and Team open the booking popup on /schedule" do
    get packages_path

    assert_select "#{cta('vibe')}[href='/build'][data-cta-target='build']", text: "Build your app"
    %w[builder pro team].each do |key|
      assert_select "#{cta(key)}[href='/schedule'][data-booking-popup='true'][data-studio-booking='true'][data-cta-target='schedule']"
    end
    assert_select "dialog[data-booking-dialog][data-studio-booking]", 1, "the popup the schedule CTAs open must be on the page"
  end

  test "Enterprise Book a call falls back to the studio's booking popup while no URL is configured" do
    get packages_path

    assert_select "#{TALK_CTA}[href='/schedule'][data-booking-popup='true'][data-studio-booking='true']", text: "Book a call"
    assert_select "#{TALK_CTA}[target]", 0, "the fallback stays on the page in the popup"
  end

  test "Enterprise Book a call opens the configured Google Calendar page in a new tab" do
    WorkspacePackage.stub(:enterprise_booking_url, BOOKING) do
      get packages_path
    end

    assert_select "#{TALK_CTA}[href='#{BOOKING}'][target='_blank'][rel='noopener'][data-cta-target='enterprise-booking']",
                  text: "Book a call"
    assert_select "#{TALK_CTA}[data-booking-popup]", 0
    assert_select "#{cta('team')}[href='/schedule']", 1, "only Enterprise takes the enterprise URL"
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
    assert_equal %w[vibe builder pro team enterprise], css_select("[data-test='stack-tier-header']").map { |th| th["data-package"] }
    assert_select "[data-test='stack-tier-header'][data-package='enterprise']", text: /Enterprise\s*Talk to us/
    assert_equal WorkspacePackage.features_by_category.map(&:first),
                 css_select("[data-test='stack-category']").map { |tbody| tbody["data-category"] }
    assert_select "[data-test='stack-row']", WorkspacePackage.features.size
    css_select("[data-test='stack-row']").each do |row|
      assert_equal 5, row.css("[data-test='stack-cell']").size, "#{row['data-feature']} must have a cell per tier"
    end
    assert_select "[data-test='stack-legend']", text: /Included.*Not included.*Coming soon.*Add-on/m
  end

  test "[component] the matrix groups Application, Domain, Security & integrations, Marketing, Agents, Service and Talk to us, with their leads" do
    get packages_stack_path

    assert_equal %w[application domain platform marketing agents service add_ons],
                 css_select("[data-test='stack-category']").map { |tbody| tbody["data-category"] }
    assert_select "[data-test='stack-category'][data-category='platform']", text: /Security & integrations/
    assert_no_match(/>\s*Platform\s*</, response.body, "no Platform heading is left")
    { "application" => "custom-web-app", "domain" => "web-address", "platform" => "branded-emails",
      "agents" => "fractional-cto", "marketing" => "social-outreach" }.each do |group, lead|
      assert_equal lead, css_select("[data-test='stack-category'][data-category='#{group}'] [data-test='stack-row']").first["data-feature"], group
    end
    assert_equal %w[web-address fast-protected-domain],
                 css_select("[data-test='stack-category'][data-category='domain'] [data-test='stack-row']").first(2).map { |tr| tr["data-feature"] }
    assert_equal [ "From Builder", "From Pro", "From Pro", "From Pro" ], css_select("[data-test='stack-category-from']").map { |n| n.text.strip }
    assert_select "[data-test='stack-category'][data-category='application'] [data-test='stack-category-from']", 0
    fast = "[data-test='stack-row'][data-feature='fast-protected-domain']"
    assert_select "#{fast} [data-test='stack-lead'][data-lead='cloudflare']"
    %w[vibe builder].each { |key| assert_select "#{fast} [data-test='stack-cell'][data-package='#{key}'][data-included='false']", 1, key }
    %w[pro team enterprise].each { |key| assert_select "#{fast} [data-test='stack-cell'][data-package='#{key}'][data-included='true'] [data-test='stack-product-name']", text: "Premium Domain" }
    assert_select "[data-feature='web-address'] [data-test='stack-lead'][data-lead='glyph-domain'] [data-glyph='domain'][aria-label='Your domain'] svg"
    assert_select "[data-feature='web-address'] [data-test='stack-lead'] [data-brand='squarespace']", 0, "Squarespace moves to the strip"
    assert_select "[data-feature='web-address'] [data-test='stack-software'] [data-brand='squarespace']"
    assert_select "[data-feature='google-workspace']", 0
    assert_select "[data-feature='integrations'] [data-test='stack-lead'][data-lead='emoji']"
    assert_select "[data-feature='integrations'] a.underline[href='/integrations']", text: "Integrations"
    assert_select "[data-feature='integrations'] [data-test='stack-software'] [data-brand='google']"
    assert_equal [ "—", "—", "Google Workspace, Discord & more", "Google Workspace, Discord & more", "Custom" ],
                 css_select("[data-feature='integrations'] [data-test='stack-cell']").map { |td| cell_text(td) }
    assert_equal [ "your-app.mcritchie.studio", "www.your-app.com", "your-app.com + www.your-app.com",
                   "your-app.com + www.your-app.com", "Multiple domains" ],
                 css_select("[data-feature='web-address'] [data-test='stack-cell']").map { |td| td.text.strip }
    vibe = "[data-feature='web-address'] [data-test='stack-cell'][data-package='vibe']"
    assert_select "#{vibe} [data-test='stack-hostnames'] [data-test='stack-hostname']", text: "your-app.mcritchie.studio" do
      assert_select "wbr", 1, "the one place it may wrap: after its first label"
    end
    assert_select "#{vibe} [class*='overflow-wrap']", 0, "a hostname never breaks mid-word"
    pro = css_select("[data-feature='web-address'] [data-test='stack-cell'][data-package='pro'] [data-test='stack-hostname']")
    assert_equal %w[your-app.com www.your-app.com], pro.map(&:text)
    assert pro.all? { |host| host["class"].to_s.include?("whitespace-nowrap") && host.css("wbr").empty? }, "a listed hostname breaks only at the plus"
  end

  test "values read across the row, with a check or a dash where nothing is quantified" do
    get packages_stack_path

    row = "[data-test='stack-row'][data-feature='host']"
    assert_equal [ "Vibe Host|light server, wakes on first visit", "Builder Host|always on", "Pro Host|always on + background jobs",
                   "Team Host|always on + background jobs", "Sized to need" ],
                 css_select("#{row} [data-test='stack-cell']").map { |td| cell_text(td) }
    assert_select "#{row} [data-test='stack-cell'][data-package='pro'] [data-test='stack-product-metric'].text-muted", text: "always on + background jobs"
    assert_equal [ "Vibe Storage|read-only, built into your app", "Builder Storage|1 GB records + 10 GB files",
                   "Pro Storage|10 GB records + 50 GB files", "Team Storage|32 GB records + 100 GB files", "Custom" ],
                 css_select("[data-feature='storage'] [data-test='stack-cell']").map { |td| cell_text(td) }
    assert_select "[data-feature='database'], [data-feature='file-storage']", 0, "one Storage row, no repeated GB"
    assert_select "[data-feature='live-updates-and-jobs'] [data-test='stack-cell'][data-package='builder']", text: "Included"
    assert_select "[data-feature='live-updates-and-jobs'] [data-test='stack-cell'][data-package='vibe']", text: "—"
    assert_select "[data-feature='cache-and-job-queue']", 0
    assert_select "[data-feature='realtime-updates']", 0
    { "builder" => "Several changes a month", "pro" => "Always-on CTO", "team" => "Always-on CTO",
      "enterprise" => "Dedicated build team" }.each do |key, text|
      assert_select "[data-feature='changes-after-launch'] [data-test='stack-cell'][data-package='#{key}']", text: text
    end
    assert_no_match(/build requests? a month|Small, queued/, response.body)
    assert_select "[data-feature='credential-rotation'] [data-test='stack-cell'][data-package='enterprise']", text: "CMMC/ITAR review on request"
    assert_select "[data-feature='https-and-deploys'] [data-test='stack-cell'][data-package='vibe']", text: "✓"
    assert_select "[data-feature='customer-sign-in'] [data-test='stack-cell'][data-package='vibe']", text: "—"
  end

  test "rows carry their software logos, and planned rows say Coming soon" do
    get packages_stack_path

    assert_select "[data-feature='storage'] [data-test='stack-lead'] [data-brand='postgres'][title='Postgres'] img"
    assert_select "[data-feature='storage'] [data-test='stack-software'] [data-brand='cloudflare'][aria-label='Cloudflare']"
    assert_select "[data-feature='email-marketing'] [data-test='stack-lead'][data-lead='emoji']"
    assert_select "[data-feature='email-marketing'] [data-test='stack-software'] [data-brand='zerobounce']"
    assert_select "[data-feature='social-posting']", 0
    assert_select "[data-feature='social-outreach'] [data-test='stack-software'] [data-brand='x']"
    assert_select "[data-feature='social-outreach'][data-status='planned'] [data-test='coming-soon']"
    assert_equal [ "—", "—", "Posts you approve", "CMO-managed", "CMO-managed" ],
                 css_select("[data-feature='social-outreach'] [data-test='stack-cell']").map { |td| cell_text(td) }
    assert_select "[data-feature='custom-connectors'] [data-test='coming-soon']"
    assert_select "[data-feature='custom-web-app'] [data-test='stack-lead'][data-lead='glyph-app'] [data-glyph='app'][aria-label='Custom app'] svg"
    assert_select "[data-feature='custom-web-app'] [data-test='stack-lead'] [data-brand='github']", 0, "GitHub moves to the strip"
    assert_equal %w[github rails], css_select("[data-feature='custom-web-app'] [data-test='stack-software'] [data-test='brand-logo']").map { |l| l["data-brand"] }
    assert_select "[data-feature='funnel-generation'][data-status='planned'] [data-test='coming-soon']"
    assert_select "[data-feature='funnel-generation'] [data-test='stack-cell'][data-package='pro']", text: "—"
    assert_select "[data-feature='funnel-generation'] [data-test='stack-cell'][data-package='team']", text: "✓"
    assert_select "[data-feature='host'] [data-test='coming-soon']", 0
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
    assert_select "#{TALK_CTA}[data-cta-action='enterprise_booking']", text: "Book a call"
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
    assert_select "[data-test='sop-map-comps']", text: /Builder — Cyvasse/
  end

  test "[component] the full stack draws ONE Cloudflare row as Premium Domain, the planned bot check, and the spotlight" do
    get packages_stack_path

    row = "[data-test='stack-row'][data-feature='fast-protected-domain'][data-status='live']"
    assert_select "#{row} [data-test='stack-lead'] [data-brand='cloudflare']"
    assert_select "#{row} [data-test='coming-soon']", 0
    assert_equal [ "—", "—" ] + [ "Premium Domain|your-app.com · fast, guarded" ] * 3,
                 css_select("#{row} [data-test='stack-cell']").map { |td| cell_text(td) }
    assert_select "#{row} [data-test='stack-blurb']", text: /\ADNS on Cloudflare's global network: faster lookups, protection from attacks/
    assert_no_match(/Cloudflare/, css_select("#{row} [data-test='stack-cell']").text, "Cloudflare lives in the detail line, not the cell")
    assert_select "[data-feature='cloudflare-dns']", 0, "the two Cloudflare rows merged"
    assert_select "[data-test='stack-cell'] span.rounded-full", 0, "a pill that wraps keeps its text inside its border"
    css_select("[data-test='stack-cell'] span.rounded-lg.border").each do |pill|
      assert_includes pill["class"], "max-w-full", "#{pill.text.strip}: a pill never grows past its cell"
    end
    assert_select "[data-feature='bot-check'][data-status='planned'] [data-test='coming-soon']"
    assert_select "[data-feature='bot-check'] [data-test='stack-lead'] [data-brand='cloudflare']"

    assert_select "[data-test='dns-flow'] h2", text: "Premium Domain, on Cloudflare"
    assert_select "[data-test='dns-flow-pitch']", text: /\APro and Team sites run on Cloudflare\. .*you never log in to a dashboard\.\z/m
    assert_equal [ "Faster to load", "Stays up under attack", "One clean address", "Changes the same day", "Email that lands",
                   "Yours, not your builder's" ],
                 css_select("[data-test='dns-flow-benefit'] .font-semibold").map { |n| n.text.strip.delete_suffix(":") }
    assert_match(/SPF, DKIM and DMARC/, css_select("[data-test='dns-flow-benefits']").text)
    rollout = "[data-test='dns-flow-rollout']"
    assert_select "#{rollout} [data-test='coming-soon']", text: "Not live yet"
    assert_equal 4, css_select("#{rollout} [data-test='dns-flow-rollout-item']").size
    [ /Turnstile/, /firewall and rate limiting/, /caching/, /analytics/ ].each do |claim|
      assert_match claim, css_select(rollout).text
      assert_no_match claim, css_select("[data-test='dns-flow-benefits']").text, "#{claim.source}: not sold as live"
    end
    assert_no_match(/\d\s*%|percent/i, css_select("[data-test='dns-flow']").text, "qualitative claims only")
    assert_select "[data-test='dns-flow-tiers']", text: "Pro, Team, and Enterprise"
    assert_select "[data-test='dns-flow'] [data-brand='cloudflare']"
    assert_equal [ "www.your-app.com", "301 → your-app.com", "your-app.com", "Served over HTTPS" ],
                 css_select("[data-test='dns-flow-step'] p.font-mono").map { |p| p.text.strip }
    %w[Welding Industries Turf].each { |client| assert_no_match(/#{client}/, css_select("[data-test='dns-flow']").to_s) }
    assert_no_match(/Commercial Welding/, response.body.sub(/data-test="sop-map".*/m, ""), "no client named on the public page")
  end
end
