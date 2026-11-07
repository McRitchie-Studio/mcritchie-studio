require "test_helper"
require "minitest/mock"
require "support/email_image_fakes"
require "support/tiktok_oauth_fakes"

# [component] The admin pages on the engine page header (task admin-pages-standard-header;
# Alex McRitchie 2026-11-07, "clean up the DOM and UI"). Each page had a hand-rolled title:
# an "A / B / C" breadcrumb (style S4), a title and a lead (S9), an h2 for the title (S10)
# or a compact tool bar (S11). Each now renders studio-engine's studio/_page_header with a
# crumb trail from config/navigation.yml, its title as the page's one h1, and no free HTML
# (actions_html). The table names every page, its title and its trail.
class AdminPageHeadersTest < ActionDispatch::IntegrationTest
  include EmailImageFakes
  include TiktokOauthFakes

  ROW = ".page-header".freeze
  ADMIN = "Admin".freeze
  BASEMENT = "Basement".freeze

  setup do
    log_in_as users(:alex)
    @character = Character.create!(name: "Header Gator", kind: "mascot", brand: "turf-monster", bio: "A test gator.")
    @brief = turf_brief(headline: "Header Check")
    @person = people(:josh_allen)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Header look")
  end

  teardown { reset_tiktok_oauth }

  # path, the h1's text, the trail's ancestor labels (root first).
  def pages
    {
      # S4: the hand-made breadcrumbs.
      "ai builder multiple" => [ admin_ai_builder_multiple_path, "AI Builder Multiple", [ ADMIN, BASEMENT ] ],
      "ai builder commit history" => [ admin_ai_builder_multiple_commit_history_path, "AI Builder Commit Cache History",
                                       [ ADMIN, BASEMENT, "AI Builder Multiple" ] ],
      "new character" => [ new_character_path, "New character", [ ADMIN, BASEMENT, "Characters" ] ],
      "edit character" => [ edit_character_path(@character), "Edit Header Gator", [ ADMIN, BASEMENT, "Characters", "Header Gator" ] ],
      "character" => [ character_path(@character), "Header Gator", [ ADMIN, BASEMENT, "Characters" ] ],
      "brand kits" => [ email_brand_kits_path, "Brand kits", [ ADMIN, BASEMENT, "Email images" ] ],
      "brand kit" => [ email_brand_kit_path("turf-monster"), EmailImages::BrandKit.find("turf-monster").label,
                       [ ADMIN, BASEMENT, "Email images", "Brand kits" ] ],
      "generator" => [ email_image_generators_path, "Email image generator", [ ADMIN, BASEMENT, "Email images" ] ],
      "generator kit" => [ email_image_generator_path("turf-monster"), "#{EmailImages::BrandKit.find('turf-monster').label} email images",
                           [ ADMIN, BASEMENT, "Email images", "Generator" ] ],
      "email brief" => [ email_image_path(@brief), "“Header Check”", [ ADMIN, BASEMENT, "Email images" ] ],
      "logos compare" => [ logos_compare_path, "Compare kits", [ ADMIN, "Logos" ] ],
      "logo brand" => [ logo_brand_path("studio"), "McRitchie Studio", [ ADMIN, "Logos" ] ],
      "logo motion" => [ logo_brand_path("studio", type: "motion"), "McRitchie Studio", [ ADMIN, "Logos" ] ],
      "look" => [ person_appearance_path(@person.slug, @look.slug), @person.full_name, [ ADMIN, BASEMENT, "People", @person.full_name ] ],
      # S9: a title and a lead.
      "csp reports" => [ admin_csp_reports_path, "CSP reports", [ ADMIN, BASEMENT ] ],
      "fathom" => [ admin_fathom_path, "Fathom connection", [ ADMIN, BASEMENT ] ],
      "google" => [ admin_google_path, "Google connection", [ ADMIN, BASEMENT ] ],
      "report destinations" => [ admin_report_destinations_path, "Report destinations", [ ADMIN, BASEMENT ] ],
      "upgrade proposals" => [ admin_upgrade_proposals_path, "Upgrade proposals", [ ADMIN, BASEMENT ] ],
      "tiktok" => [ admin_tiktok_path, "TikTok connection", [ ADMIN, BASEMENT ] ],
      "books" => [ books_path, "Books", [ ADMIN ] ],
      "broadcasts" => [ broadcasts_path, "Broadcasts", [ ADMIN, BASEMENT ] ],
      "contacts" => [ contacts_path, "Contacts", [ ADMIN, BASEMENT ] ],
      "email analytics" => [ broadcast_analytics_path, "Email analytics", [ ADMIN, BASEMENT, "Broadcasts" ] ],
      "model pricing" => [ admin_model_pricing_path, "Model Pricing", [ ADMIN ] ],
      "body archetypes" => [ body_archetypes_path, "Body archetypes", [ ADMIN, BASEMENT ] ],
      "characters" => [ characters_path, "Characters", [ ADMIN, BASEMENT ] ],
      "email images" => [ email_images_path, "Email images", [ ADMIN, BASEMENT ] ],
      "logos" => [ logos_path, "Logos", [ ADMIN ] ],
      # S10: an h2 for the title.
      "contents" => [ contents_path, "Content Pipeline", [ ADMIN, BASEMENT ] ],
      "news" => [ news_index_path, "News Pipeline", [ ADMIN, BASEMENT ] ],
      "people" => [ people_path, "People", [ ADMIN, BASEMENT ] ],
      "teams" => [ teams_path, "Teams", [ ADMIN, BASEMENT ] ],
      "duplicates" => [ duplicates_people_path, "Duplicate Scanner", [ ADMIN, BASEMENT, "People" ] ],
      "merge" => [ merge_people_path, "Merge People", [ ADMIN, BASEMENT, "People" ] ],
      "docs" => [ docs_path, "Agent Docs", [ ADMIN, BASEMENT ] ],
      "model pipeline" => [ model_pipeline_path, "Model Pipeline", [ ADMIN, BASEMENT ] ],
      "usage" => [ usages_path, "Usage", [ ADMIN, BASEMENT ] ],
      # S11: a compact tool bar.
      "agent inbox" => [ admin_agent_messages_path, "Agent inbox", [ ADMIN, BASEMENT ] ],
      "desk" => [ admin_desk_path, "Desk", [ ADMIN, BASEMENT ] ],
      "communications" => [ communications_path, "Communications", [ ADMIN, BASEMENT ] ]
    }
  end

  # Gets the page with the engine's actions_html deprecation hook armed.
  def get_header(path, expect: :success, **params)
    sites = []
    Studio::PageHeader.stub(:warning_enabled?, true) do
      Studio::PageHeader.stub(:deprecate_actions_html, ->(site: nil, **) { sites << site }) do
        get path, params: params
      end
    end
    assert_response expect, path
    assert_empty sites, "#{path} passes actions_html to studio/page_header"
  end

  def assert_standard_header(name, title, ancestors)
    assert_equal 1, css_select("#{ROW}").size, "#{name}: one engine page header"
    assert_equal [ title ], css_select("h1").map { |h1| h1.text.strip }, "#{name}: one h1, the header's title"
    assert_select "#{ROW} h1.page-header-title", { text: title, count: 1 }, name
    assert_equal ancestors, css_select("#{ROW} nav.page-header-crumbs a.page-header-crumb").map { |a| a.text.strip },
                 "#{name}: the crumb trail"
    assert_select "#{ROW} .page-header-crumb-current[aria-current=page]", 1
    assert_select "#{ROW} a.page-header-parent", 1
  end

  test "[component] every converted admin page renders studio/page_header with crumbs and one h1" do
    pages.each do |name, (path, title, ancestors)|
      get_header path
      assert_standard_header(name, title, ancestors)
    end
  end

  test "[component] the TikTok callback pages: connected and refused, under TikTok connection" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      get admin_tiktok_connect_path
      state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
      get_header admin_tiktok_callback_path, state:, code: "code-1"
      assert_standard_header("tiktok callback", "TikTok connected and saved", [ ADMIN, BASEMENT, "TikTok connection" ])

      get admin_tiktok_connect_path
      state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
      get_header admin_tiktok_callback_path, expect: :bad_request, state:, error: "access_denied"
      assert_standard_header("tiktok refused", "TikTok did not connect", [ ADMIN, BASEMENT, "TikTok connection" ])
    end
  end

  # The old headers' buttons, each now one of the engine's four kinds of control
  # (studio-engine docs/PAGE_HEADER.md): every link is still on the page.
  def menu_hrefs = css_select("#{ROW} .page-header-menu-list a.page-header-menu-item").map { |a| a["href"] }
  def anchor_hrefs = css_select("#{ROW} nav.page-header-tabs[data-page-header-kind=anchors] a.page-header-tab").map { |a| a["href"] }

  test "[component] the old header buttons are the engine's kinds: anchors, the Links menu, one action, tabs" do
    get_header admin_ai_builder_multiple_path
    assert_equal %w[#commit-log #tracked-builders], anchor_hrefs
    assert_equal [ admin_ai_builder_multiple_path(format: :json) ], menu_hrefs

    get_header email_images_path
    assert_equal [ email_image_generators_path, email_brand_kits_path ], menu_hrefs

    get_header email_image_generator_path("turf-monster")
    assert_select "#{ROW} [data-test=brand-kit-link][href=?]", email_brand_kit_path("turf-monster")

    get_header characters_path
    assert_select "#{ROW} a.page-header-action[href=?][data-test=new-character]", new_character_path, count: 1

    get_header character_path(@character)
    assert_select "#{ROW} a.page-header-action[href=?][data-test=edit-character]", edit_character_path(@character), text: "Edit"

    get_header contacts_path
    assert_equal [ broadcasts_path, broadcast_analytics_path ], menu_hrefs

    get_header broadcasts_path
    assert_equal [ broadcast_analytics_path ], menu_hrefs

    get_header broadcast_analytics_path
    assert_equal [ cyvasse_four_scoreboard_path ], menu_hrefs
    assert_select "form[action=?] select#broadcast", broadcast_analytics_path

    get_header contents_path
    assert_select "#{ROW} a.page-header-action[href=?]", new_content_path, text: "New Idea"

    get_header news_index_path
    assert_select "#{ROW} a.page-header-action[href=?]", new_news_path, text: "New Article"

    get_header duplicates_people_path
    assert_equal [ merge_people_path ], menu_hrefs
    get_header merge_people_path
    assert_equal [ duplicates_people_path ], menu_hrefs

    get_header model_pipeline_path
    assert_equal [ people_path ], menu_hrefs
    assert_select "[data-test=pipeline-counts] [data-test=pipeline-total]", 1

    get_header admin_ai_builder_multiple_commit_history_path
    assert_includes menu_hrefs, admin_ai_builder_multiple_path
  end

  test "[component] /admin/desk: each status is a tab with its count, the current one marked" do
    get_header admin_desk_path
    tabs = css_select("#{ROW} nav.page-header-tabs[aria-label='Desk status'] a.page-header-tab")
    assert_equal [ admin_desk_path, *DeskCaptureItem::STATUSES.map { |s| admin_desk_path(status: s) } ], tabs.map { |a| a["href"] }
    assert_select "#{ROW} a.page-header-tab[aria-current=page][href=?]", admin_desk_path

    status = DeskCaptureItem::STATUSES.first
    get_header admin_desk_path, status: status
    assert_select "#{ROW} a.page-header-tab[aria-current=page][href=?]", admin_desk_path(status: status), text: /#{status} \(\d+\)/
  end

  test "[component] the S11 tallies are the header's meta, with a phone-only copy" do
    get_header admin_agent_messages_path
    assert_select "#{ROW} .page-header-meta [data-test=am-tallies]", text: /waiting · .* claimed · .* held · .* dead/
    assert_select "[data-test=am-tallies-phone].sm\\:hidden", text: /waiting/

    get_header communications_path
    assert_select "#{ROW} .page-header-meta [data-test=comm-tallies]", text: /open ask/
    assert_select "[data-test=comm-tallies-phone].sm\\:hidden", text: /open ask/
  end

  test "[component] a logos page: the type tabs are the header's tabs, and the Logos crumb keeps the context" do
    get_header logo_brand_path("turf", type: "stacked", context: "watermark")
    assert_select "#{ROW}[data-test=logo-header] nav.page-header-tabs[aria-label='Logo type'][data-test=logo-tabs]", 1 do
      assert_equal %w[icon navbar stacked motion], css_select("a.page-header-tab[data-test=logo-tab]").map { |a| a["data-type"] }
      assert_equal [ "stacked" ], css_select("a[data-test=logo-tab][aria-current=page]").map { |a| a["data-type"] }
    end
    assert_select "#{ROW} a.page-header-crumb[href=?]", logos_path(context: "watermark"), text: "Logos"
    assert_select "[data-test=logo-header-bar] form[data-test=context-form][action=?]", logo_brand_path("turf")
    assert_select "[data-test=logo-header-bar] [data-test=kit-status] a", 1

    get_header logos_path(context: "watermark")
    assert_select "#{ROW} [data-test=compare-link]", 1
    assert_select "[data-test=logo-header-bar] form[data-test=context-form]", 1

    get_header logos_compare_path(context: "watermark")
    assert_select "#{ROW} a.page-header-crumb[href=?]", logos_path(context: "watermark")
  end
end
