require "test_helper"

class LinkTreeHelperTest < ActiveSupport::TestCase
  include LinkTreeHelper

  test "sidebar links include hover emoji transitions" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    assert links.any? { |link| link[:label] == "Build" && link[:hover_emoji].present? }
    assert links.all? { |link| link[:hover_emoji].present? }, "expected every sidebar link to define hover_emoji"
  end

  # The glass sidebar (Alex McRitchie, 2026-11-04). App rows keep their portrait and rocket.
  # Every other row names one line icon, keeps its emoji as the fallback, and the engine
  # holds the name.
  test "each sidebar row but an app names a line icon and keeps its emoji" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    apps, rows = links.partition { |link| link[:hover_emoji] == "🚀" && link[:icon].blank? }

    assert_equal({ "Dashboard" => "chart-column", "DevOps" => "rocket", "Design" => "palette", "Branding Kits" => "diamond",
                   "App Requests" => "inbox", "Books" => "book-open", "Activities" => "activity", "Basement" => "door-stairwell",
                   "Build" => "hammer", "Chat" => "message-circle", "Portfolio" => "globe", "Packages" => "package",
                   "Integrations" => "plug" }, rows.to_h { |link| link.values_at(:label, :icon) }.except(*apps.map { |link| link[:label] }))
    assert rows.all? { |link| link[:emoji].present? }, "the emoji stays the fallback"
    assert links.any? { |link| link[:label] == "Books" }, "control: this reads an admin's rows"
    # The locked engine may not hold the icon set yet; once it does, it holds every name.
    assert_empty rows.pluck(:icon).reject { |name| Studio::Icons.known?(name) }, "the engine vendors every name" if defined?(Studio::Icons)
  end

  test "the sign-in row names a line icon too" do
    self.logged_in_enabled = false

    assert_equal "key-round", visitor_link_sections.first.fetch(:links).first.fetch(:icon)
  end

  # Alex McRitchie, 2026-11-04: "this admin section reads Dashboard, DevOps, Design,
  # Basement", then "Don't move logos to the Basement, but call it Branding Kits", then
  # "Move 'App Requests' to the 'Admin' section with 'Books'. Move the rest to the
  # basement", then "Add activities to Admin section and the rest to the basement". The
  # short words are the section's own; those pages keep their labels for the sub-navs
  # (see navigation_test.rb).
  test "admin sidebar starts with the main admin areas and omits the removed devops page" do
    self.admin_enabled = true

    sections = sidebar_link_sections
    links = sections.flat_map { |section| section.fetch(:links) }

    assert_equal "Admin", sections.first.fetch(:title)
    assert sections.first.fetch(:admin)
    assert_equal [ [ "Dashboard", "/admin" ], [ "DevOps", "/deployments" ], [ "Design", "/admin/style" ], [ "Branding Kits", "/logos" ],
                   [ "App Requests", "/build/requests" ], [ "Books", "/books" ], [ "Activities", "/agents/activities" ],
                   [ "Basement", "/admin/basement" ] ],
                 sections.first.fetch(:links).map { |link| link.values_at(:label, :href) }
    # DevOps is now a word this section shows, so the removed page is held by its address alone.
    refute links.any? { |link| link[:href] == "/devops" }
  end

  # "A page of links ... including Emails, Schema, Link Preview, and Assets". Each keeps its route.
  test "the Basement holds the moved pages, and none of them reaches the sidebar" do
    self.admin_enabled = true

    moved = [ [ "Schema", "/admin/schema" ], [ "Emails", "/admin/emails" ],
              [ "Link preview", "/admin/link_preview" ], [ "Assets", "/assets" ],
              [ "Stack", "/stack" ], [ "Credentials", "/credentials" ],
              [ "Broadcasts", "/broadcasts" ], [ "Contacts", "/contacts" ], [ "Email analytics", "/broadcasts/analytics" ],
              [ "Error logs", "/error_logs" ], [ "TikTok connection", "/admin/tiktok" ], [ "Google connection", "/admin/google" ],
              [ "Fathom connection", "/admin/fathom" ], [ "Egnyte connection", "/admin/egnyte" ], [ "QuickBooks connection", "/admin/quickbooks" ], [ "Agent inbox", "/admin/agent_messages" ],
              [ "Report destinations", "/admin/report_destinations" ], [ "CSP reports", "/admin/csp_reports" ],
              [ "Upgrade proposals", "/admin/upgrade_proposals" ],
              [ "Teams", "/teams" ], [ "People", "/people" ], [ "Builders", "/builders" ], [ "Docs", "/docs" ],
              [ "AI Builder Multiple", "/admin/ai_builder_multiple" ], [ "News workflow", "/news/workflow" ],
              [ "Merge people", "/people/merge" ], [ "Duplicates", "/people/duplicates" ],
              [ "News", "/news" ], [ "Content", "/contents" ], [ "Models", "/model_pipeline" ],
              [ "Body archetypes", "/body-archetypes" ], [ "Videos", "/videos" ], [ "Alt videos", "/alt_videos" ],
              [ "NFL Hub", "/nfl" ], [ "2026 Season", "/games/2026" ] ]
    apps = Satellite.active.map(&:display_name)
    assert_equal moved, basement_links.reject { |link| apps.include?(link[:label]) }.map { |link| link.values_at(:label, :href) }

    sidebar_hrefs = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:href) }
    assert_empty moved.map(&:last) & sidebar_hrefs
    assert_includes sidebar_hrefs, "/deployments", "control: the sidebar this reads is an admin's"
  end

  test "the Basement shows each page's description, and nothing to a non-admin" do
    self.admin_enabled = true
    assert basement_links.all? { |link| link[:desc].present? && link[:hover_emoji].present? }

    self.admin_enabled = false
    assert_empty basement_link_sections
  end

  # The adoption of the engine's standard email page: the Basement points at the
  # shared /admin/emails, not the retired /admin/email_images fork. Asserted on
  # the href because the label alone would still pass if the link were repointed.
  test "the Basement links the shared emails page, not the retired image page" do
    self.admin_enabled = true

    emails = basement_links.find { |link| link[:label] == "Emails" }

    assert emails, "the Basement should carry an Emails link"
    assert_equal "/admin/emails", emails.fetch(:href)
    refute (basement_links + sidebar_link_sections.flat_map { |section| section.fetch(:links) }).any? { |link| link[:href] == "/admin/email_images" }
  end

  # task hub-adopts-link-preview: the engine's site-identity page (studio-engine
  # 0.82) is reached from the hub's own admin menu. The second assertion pins the
  # stubbed href to the route the engine actually draws in this app.
  test "the Basement links the engine link preview page" do
    self.admin_enabled = true

    preview = basement_links.find { |link| link[:label] == "Link preview" }

    assert_equal "/admin/link_preview", preview&.fetch(:href)
    assert_equal "/admin/link_preview", Rails.application.routes.url_helpers.admin_link_preview_path
  end

  test "the Basement links the object store browser" do
    self.admin_enabled = true

    assets = basement_links.find { |link| link[:label] == "Assets" }

    assert_equal "/assets", assets&.fetch(:href)
    assert_equal "/assets", Rails.application.routes.url_helpers.asset_browser_path
  end

  test "the Clients, Email, Finance, Ops, Directory, Data, Video and Services sections leave the sidebar" do
    self.admin_enabled = true

    titles = sidebar_link_sections.map { |section| section.fetch(:title) }

    assert_includes titles, "Admin", "control: the sidebar this reads is an admin's"
    assert_empty titles & %w[Clients Email Finance Ops Site Directory Data Video Services Build]
  end

  # task contacts-admin-page: the mailing list sits beside the broadcasts sent to it.
  test "the Basement has an Email section with Broadcasts then Contacts" do
    self.admin_enabled = true

    email = basement_link_sections.find { |section| section[:title] == "Email" }

    assert_equal [ "/broadcasts", "/contacts", "/broadcasts/analytics" ], email&.fetch(:links)&.map { |link| link.fetch(:href) }
  end

  test "admin sidebar includes the Activities feed link" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    activities = links.find { |link| link[:label] == "Activities" }

    assert activities, "expected an Activities link in the admin sidebar"
    assert_equal "🎭", activities[:emoji]
    assert_equal "/agents/activities", activities[:href]
  end

  # THE MODEL PIPELINE BOARD IS REACHABLE BY CLICKING. The same argument the person page
  # makes for the model page it links to: a surface only reachable by knowing a URL is a
  # surface the operator does not have.
  test "the Basement links the model pipeline board" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    models = basement_links.find { |link| link[:label] == "Models" }

    assert models, "expected a Models link in the Basement"
    assert_equal "/model_pipeline", models.fetch(:href)
    assert models[:hover_emoji].present?
  end

  # "Studio" names the sidebar's public section now, so the Basement holds no section of
  # that name: the old Studio pages sit under Directory and Pipelines.
  test "the Basement has Directory, Data and Pipelines sections, and none named Studio" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    sections = basement_link_sections.to_h { |section| [ section.fetch(:title), section.fetch(:links).map { |link| link.fetch(:href) } ] }

    assert_equal %w[Site Clients Email Ops Directory Data Pipelines NFL Apps], sections.keys
    assert_equal [ "/teams", "/people", "/builders", "/docs" ], sections.fetch("Directory")
    assert_equal [ "/news", "/contents", "/model_pipeline", "/body-archetypes", "/videos", "/alt_videos" ], sections.fetch("Pipelines")
  end

  test "public (non-admin) sidebar omits the Activities admin link" do
    self.admin_enabled = false

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    refute links.any? { |link| link[:label] == "Activities" }
  end

  # [component] The engine's living style guide (/admin/style) is reachable from
  # the admin sidebar, and the engine-provided route resolves in this host app.
  test "admin sidebar exposes the Design System page link, under the word Design" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    design_system = links.find { |link| link[:label] == "Design" }

    assert design_system, "expected a Design link in the admin sidebar"
    assert_equal admin_style_path, design_system.fetch(:href)
    assert_equal "🎨", design_system.fetch(:emoji)
    assert design_system.fetch(:hover_emoji).present?, "expected a hover_emoji on the Design System link"

    # The canonical /admin/style route is bundled by studio-engine (0.18+) — confirm
    # it resolves here.
    assert_equal "/admin/style", Rails.application.routes.url_helpers.admin_style_path
  end

  test "admin sidebar links DevOps to the deploy lane board" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    deployments = links.find { |link| link[:label] == "DevOps" }

    assert deployments, "expected an admin DevOps link"
    assert_equal deployments_path, deployments.fetch(:href)
  end

  test "public sidebar omits the deploy lane board" do
    self.admin_enabled = false

    hrefs = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:href] }

    refute_includes hrefs, deployments_path
  end

  test "logged-out sidebar shows only the public sections" do
    self.admin_enabled = false
    self.logged_in_enabled = false

    sections = sidebar_link_sections

    assert_equal %w[Account Studio], sections.map { |section| section.fetch(:title) }
    labels = sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:label] }
    refute_includes labels, "Studio dashboard"
    refute_includes labels, "Dashboard"
    refute_includes labels, "Basement"
    refute_includes labels, "Agents"
    refute_includes labels, "Builders"
    refute_includes labels, "Teams"
    refute_includes labels, "People"
  end

  # Alex McRitchie, 2026-11-04: "change this to 'Studio' and have the first be Build so we
  # can remove the App Builder", with Packages and Integrations in it, at every level.
  test "the Studio section reads Build, Chat, Portfolio, Packages, Integrations at every level" do
    rows = [ "Build", "Chat", "Portfolio", "Packages", "Integrations" ]
    hrefs = [ "/build", "/chat", "/websites", "/packages", "/integrations" ]

    [ [ false, false ], [ false, true ], [ true, true ] ].each do |admin, logged_in|
      self.admin_enabled = admin
      self.logged_in_enabled = logged_in

      studio = sidebar_link_sections.select { |section| section.fetch(:title) == "Studio" }
      assert_equal 1, studio.size
      assert_equal rows, studio.first.fetch(:links).map { |link| link.fetch(:label) }
      assert_equal hrefs, studio.first.fetch(:links).map { |link| link.fetch(:href) }
      assert studio.first.fetch(:links).all? { |link| link[:hover_emoji].present? }
      refute sidebar_link_sections.flat_map { |section| section.fetch(:links) }.any? { |link| link[:label] == "App Builder" }
    end
  end

  test "/links reads the Studio section with its descriptions, then NFL and the apps" do
    self.admin_enabled = false
    self.logged_in_enabled = false

    assert_equal %w[Studio NFL Apps], links_page_sections.map { |section| section.fetch(:title) }
    described = links_page_sections.first.fetch(:links).to_h { |link| [ link.fetch(:label), link[:desc].present? ] }
    assert_equal({ "Build" => true, "Chat" => false, "Portfolio" => false, "Packages" => true, "Integrations" => true }, described)
  end

  test "the Basement has a Clients section with Stack and Credentials; App Requests leads to Admin instead" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    clients = basement_link_sections.find { |section| section.fetch(:title) == "Clients" }

    assert_equal [ "/stack", "/credentials" ], clients&.fetch(:links)&.map { |link| link.fetch(:href) }
    refute_includes basement_links.map { |link| link[:href] }, "/build/requests"
  end

  test "non-admins never see the admin pages that moved" do
    self.admin_enabled = false
    self.logged_in_enabled = true

    hrefs = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:href] }
    assert_empty hrefs & [ "/build/requests", "/books", "/stack", "/credentials", "/broadcasts", "/contacts" ]
    assert_empty basement_link_sections
  end

  test "a signed-in non-admin sees only the public sections" do
    self.admin_enabled = false
    self.logged_in_enabled = true

    assert_equal %w[Studio], sidebar_link_sections.map { |section| section.fetch(:title) }
  end

  # Alex McRitchie, 2026-11-04: "I don't see a purpose for /dashboard"; Applications and
  # Agents "are viewable from the admin dashboard"; Tasks "we can drop as Devops is a
  # better version". They leave every list; their routes stay.
  test "an admin's sidebar is Admin and Studio, and the four dropped pages are in no list" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    assert_equal [ "NFL", "Apps" ], public_link_sections.map { |section| section.fetch(:title) }
    assert_equal %w[Admin Studio], sidebar_link_sections.map { |section| section.fetch(:title) }

    every_list = sidebar_link_sections + links_page_sections + admin_link_sections + basement_link_sections
    hrefs = every_list.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:href) }
    assert_includes hrefs, "/deployments", "control: these are an admin's lists"
    assert_empty hrefs & [ "/dashboard", "/applications", "/agents", "/tasks" ]
    assert_empty sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:href) } &
                 [ "/builders", "/news", "/contents", "/model_pipeline", "/body-archetypes", "/videos",
                   "/teams", "/people", "/docs", "/admin/ai_builder_multiple", "/news/workflow", "/people/merge",
                   "/people/duplicates", "/alt_videos" ]
  end

  # task public-nfl-cards-stay-public: both NFL links are public pages, so the
  # section is no longer hidden from visitors; the walled Directory still is.
  test "visitors get the public NFL section and never the Directory" do
    self.admin_enabled = false
    self.logged_in_enabled = false

    nfl = public_link_sections.find { |section| section.fetch(:title) == "NFL" }

    assert nfl, "a visitor should see the NFL section"
    assert_equal [ "/nfl", "/games/2026" ], nfl.fetch(:links).map { |link| link.fetch(:href) }
    refute public_link_sections.any? { |section| section.fetch(:title) == "Directory" }
  end

  # The navbar carries no sign-in link, so a visitor finds Sign In at the top of
  # the sidebar (/tasks/drop-hero-meet-alex); a signed-in user does not.
  test "a visitor's sidebar leads with Sign In and Chat; a signed-in user's drops Sign In and keeps Chat" do
    first = sidebar_link_sections.first
    assert_equal "Account", first.fetch(:title)
    assert_equal [ [ "Sign In", "/signin" ] ], first.fetch(:links).map { |link| link.values_at(:label, :href) }
    assert_equal %w[Account Studio], sidebar_link_sections.map { |section| section.fetch(:title) }
    chat = sidebar_link_sections.last.fetch(:links).find { |link| link[:label] == "Chat" }
    assert_equal "/chat", chat.fetch(:href)
    assert_includes chat.fetch(:emoji), "/agents/alex.webp"
    assert_equal "💬", chat.fetch(:hover_emoji)
    assert sidebar_link_sections.flat_map { |section| section.fetch(:links) }.none? { |link| link.key?(:desc) }, "a visitor's link is one line"

    self.logged_in_enabled = true
    self.current_user = nil
    refute sidebar_link_sections.any? { |section| section[:title] == "Account" }
    refute sidebar_link_sections.flat_map { |section| section.fetch(:links) }.any? { |link| link[:href] == "/signin" }
    assert_equal [ "Build", "Chat", "Portfolio", "Packages", "Integrations" ], signed_in_studio_links
    assert_equal 1, sidebar_link_sections.count { |section| section[:title] == "Studio" }

    self.admin_enabled = true
    assert_equal [ "Build", "Chat", "Portfolio", "Packages", "Integrations" ], signed_in_studio_links, "an admin is signed in, so an admin has them too"
    assert_equal 1, sidebar_link_sections.count { |section| section[:title] == "Studio" }
  end

  private

  attr_accessor :admin_enabled, :logged_in_enabled, :current_user

  def basement_links
    basement_link_sections.flat_map { |section| section.fetch(:links) }
  end

  def signed_in_studio_links
    sidebar_link_sections.find { |section| section[:title] == "Studio" }.fetch(:links).map { |link| link.fetch(:label) }
  end

  def admin?
    !!admin_enabled
  end

  # An admin is always signed in.
  def logged_in?
    !!(logged_in_enabled || admin_enabled)
  end

  def dashboard_path = "/dashboard"
  def applications_path = "/applications"
  def logos_path = "/logos"
  def agents_path = "/agents"
  def builders_path = "/builders"
  def tasks_path = "/tasks"
  def news_index_path = "/news"
  def contents_path = "/contents"
  # ADDING A PAGE TO THE SIDEBAR IN config/navigation.yml MEANS ADDING ITS STUB HERE.
  # This class is an ActiveSupport::TestCase and includes the helper directly, so no
  # route helper is defined for it: a new link raises NoMethodError in every test in
  # this file.
  def model_pipeline_path = "/model_pipeline"
  def body_archetypes_path = "/body-archetypes"
  def videos_path = "/videos"
  def broadcasts_path = "/broadcasts"
  def contacts_path = "/contacts"
  def broadcast_analytics_path = "/broadcasts/analytics"
  def nfl_hub_path = "/nfl"
  def games_season_path(year) = "/games/#{year}"
  def teams_path = "/teams"
  def people_path = "/people"
  def docs_path = "/docs"
  def packages_path = "/packages"
  def integrations_path = "/integrations"
  def build_path = "/build"
  def signin_path = "/signin"
  def build_requests_path = "/build/requests"
  def stack_path = "/stack"
  def credentials_path = "/credentials"
  def books_path = "/books"
  def deployments_path = "/deployments"
  def admin_dashboard_path = "/admin"
  def admin_basement_path = "/admin/basement"
  def admin_style_path = "/admin/style"
  def websites_path = "/websites"
  def chat_index_path = "/chat"
  def safe_image_tag(url, **) = %(<img src="#{url}">).html_safe
  def admin_schema_path = "/admin/schema"
  def admin_emails_path = "/admin/emails"
  def admin_link_preview_path = "/admin/link_preview"
  def asset_browser_path = "/assets"
  def admin_tiktok_path = "/admin/tiktok"
  def admin_google_path = "/admin/google"
  def admin_fathom_path = "/admin/fathom"
  def admin_egnyte_path = "/admin/egnyte"
  def admin_quickbooks_path = "/admin/quickbooks"
  def activities_agents_path = "/agents/activities"
  def admin_ai_builder_multiple_path = "/admin/ai_builder_multiple"
  def workflow_news_index_path = "/news/workflow"
  def merge_people_path = "/people/merge"
  def duplicates_people_path = "/people/duplicates"
  def alt_videos_path = "/alt_videos"
  def error_logs_path = "/error_logs"
  def admin_agent_messages_path = "/admin/agent_messages"
  def admin_report_destinations_path = "/admin/report_destinations"
  def admin_csp_reports_path = "/admin/csp_reports"
  def admin_upgrade_proposals_path = "/admin/upgrade_proposals"
  # The engine's _link_sidebar draws the header (link-sidebar-section-headers, its own
  # task, default off). Until it ships the key changes nothing, so these read the hash.
  test "[component] My Apps, Admin and Studio carry header: true, and Account does not" do
    users(:alex).save!
    AppMembership.create!(app: apps(:turf_monster), user: users(:alex))
    self.admin_enabled = true
    self.logged_in_enabled = true
    self.current_user = users(:alex)

    sections = sidebar_link_sections.to_h { |section| [ section.fetch(:title), section ] }
    assert_equal({ "My Apps" => true, "Admin" => true, "Studio" => true }, sections.transform_values { |section| section[:header] })

    self.admin_enabled = false
    self.logged_in_enabled = false
    self.current_user = nil
    visitor = sidebar_link_sections.to_h { |section| [ section.fetch(:title), section ] }
    assert_equal %w[Account Studio], visitor.keys
    refute visitor.fetch("Account").key?(:header), "Sign In sits under no header"
    assert visitor.fetch("Studio")[:header]

    self.admin_enabled = true
    assert basement_link_sections.any?, "control: the Basement has sections"
    assert basement_link_sections.none? { |section| section.key?(:header) }, "the Basement page draws its own titles"
  end

  # Alex McRitchie, 2026-11-04, of the admin sidebar: "Lets move these all to the basement".
  test "[component] NFL Hub, 2026 Season and the two apps left the sidebar for the Basement, and /links keeps them" do
    self.logged_in_enabled = true
    self.admin_enabled = true
    rows = %w[NFL\ Hub 2026\ Season Turf\ Monster McRitchie\ Industries]
    labels = ->(sections) { sections.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:label) } }

    assert_empty labels.call(sidebar_link_sections) & rows
    assert_equal rows, labels.call(basement_link_sections) & rows
    assert_equal rows, labels.call(links_page_sections) & rows

    turf = basement_links.find { |link| link[:label] == "Turf Monster" }
    assert_equal "_blank", turf[:target]
    assert turf[:desc].present?, "the Basement describes an app"
    refute links_page_sections.flat_map { |section| section.fetch(:links) }.find { |link| link[:label] == "Turf Monster" }.key?(:desc)

    self.admin_enabled = false
    assert_empty labels.call(sidebar_link_sections) & rows
    assert_equal rows, labels.call(links_page_sections) & rows
  end

  # Alex McRitchie, 2026-11-04: "give [these] the section title Studio".
  test "[component] the five Studio rows sit under the Studio header for a visitor, a user and an admin" do
    [ [ false, false ], [ true, false ], [ true, true ] ].each do |signed_in, admin|
      self.logged_in_enabled = signed_in
      self.admin_enabled = admin
      studio = sidebar_link_sections.find { |section| section[:title] == "Studio" }
      assert studio.fetch(:header), "signed_in=#{signed_in} admin=#{admin}"
      assert_equal %w[Build Chat Portfolio Packages Integrations], studio.fetch(:links).map { |link| link.fetch(:label) }
    end
  end

  # The production order (Alex McRitchie's four, 2026-11-04): position, then name, so
  # the two client-position rows stay ahead of alex.build and Voicebox.
  test "[component] with four memberships the sidebar shows the two lowest positions, then All N Apps" do
    owner = users(:alex)
    owner.save!
    team_notes = App.create!(slug: "team-notes", name: "Team Voice Notes to Webhook", position: 0)
    alex_build = App.create!(slug: "alex-build", name: "alex.build", position: 15)
    voicebox = App.create!(slug: "voicebox", name: "Voicebox", position: 16)
    [ apps(:mcritchie_studio), team_notes, alex_build, voicebox ].each { |app| AppMembership.create!(app: app, user: owner) }
    self.admin_enabled = false
    self.logged_in_enabled = true
    self.current_user = owner

    assert_equal [ "McRitchie Studio", "Team Voice Notes to Webhook", "All #{App.count} Apps" ],
                 sidebar_link_sections.first.fetch(:links).map { |link| link.fetch(:label) }
  end

  # [component] The owner section (AppOwnership.sidebar_links): first in the
  # sidebar, at most two apps by name and All N Apps third, every row swapping to a
  # rocket; absent for a signed-in user who owns nothing and for a visitor.
  test "[component] an owner's sidebar opens with up to two apps, and All N Apps third for three or more" do
    owner = User.create!(email: "sidebar-owner@example.com", name: "Sidebar Owner", role: "viewer")
    cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse", emoji: "🐉", color: "#DC2626", position: 5)
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    self.admin_enabled = false
    self.logged_in_enabled = true
    self.current_user = owner

    first = sidebar_link_sections.first
    assert_equal "My Apps", first.fetch(:title)
    assert first.fetch(:header), "the owner section asks for its header"
    assert_equal [ [ "Turf Monster", "/applications/turf-monster" ] ],
                 first.fetch(:links).map { |link| [ link.fetch(:label), link.fetch(:href) ] }
    assert first.fetch(:links).all? { |link| link[:hover_emoji] == "🚀" }

    AppMembership.create!(app: cyvasse, user: owner)
    assert_equal 2, sidebar_link_sections.first.fetch(:links).size
    assert_not_includes sidebar_link_sections.first.fetch(:links).map { |link| link.fetch(:label) }.join, "All "

    AppMembership.create!(app: apps(:mcritchie_studio), user: owner)
    links = sidebar_link_sections.first.fetch(:links)
    assert_equal 3, links.size
    assert_equal [ "All 3 Apps", "/applications" ], links.last.values_at(:label, :href)
    assert links.all? { |link| link[:hover_emoji] == "🚀" }

    self.current_user = User.create!(email: "sidebar-none@example.com", name: "No Apps", role: "viewer")
    assert_equal %w[Studio], sidebar_link_sections.map { |section| section.fetch(:title) }

    self.logged_in_enabled = false
    self.current_user = nil
    refute sidebar_link_sections.any? { |section| section.fetch(:title) == "My Apps" }
  end
end
