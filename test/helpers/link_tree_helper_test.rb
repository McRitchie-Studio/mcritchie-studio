require "test_helper"

class LinkTreeHelperTest < ActiveSupport::TestCase
  include LinkTreeHelper

  test "sidebar links include hover emoji transitions" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    assert links.any? { |link| link[:label] == "Turf Monster" && link[:hover_emoji].present? }
    assert links.all? { |link| link[:hover_emoji].present? }, "expected every sidebar link to define hover_emoji"
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
              [ "Fathom connection", "/admin/fathom" ], [ "Agent inbox", "/admin/agent_messages" ],
              [ "Report destinations", "/admin/report_destinations" ], [ "CSP reports", "/admin/csp_reports" ],
              [ "Builders", "/builders" ], [ "News", "/news" ], [ "Content", "/contents" ], [ "Models", "/model_pipeline" ],
              [ "Body archetypes", "/body-archetypes" ], [ "Videos", "/videos" ] ]
    assert_equal moved, basement_links.map { |link| link.values_at(:label, :href) }

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

  test "the Clients, Email, Finance and Ops sections leave the sidebar; Data and Video stay" do
    self.admin_enabled = true

    titles = sidebar_link_sections.map { |section| section.fetch(:title) }

    assert_includes titles, "Admin", "control: the sidebar this reads is an admin's"
    assert_empty titles & %w[Clients Email Finance Ops Site]
    assert_equal %w[Data Video], titles & %w[Data Video]
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

  # Alex McRitchie, 2026-11-04, on the Studio section: /builders "should go to the
  # basement", and News, Content, Models, Body archetypes, Videos "can all go to the basement".
  test "the Basement has a Studio section: Builders, News, Content, Models, Body archetypes, Videos" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    studio = basement_link_sections.find { |section| section.fetch(:title) == "Studio" }

    assert_equal [ "/builders", "/news", "/contents", "/model_pipeline", "/body-archetypes", "/videos" ],
                 studio&.fetch(:links)&.map { |link| link.fetch(:href) }
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

    assert_equal %w[Account Build], sections.map { |section| section.fetch(:title) }
    labels = sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:label] }
    refute_includes labels, "Studio dashboard"
    refute_includes labels, "Dashboard"
    refute_includes labels, "Basement"
    refute_includes labels, "Agents"
    refute_includes labels, "Builders"
    refute_includes labels, "Teams"
    refute_includes labels, "People"
  end

  test "a signed-in user's sidebar links the App Builder, packages and integrations; a visitor reaches them from the footer" do
    self.admin_enabled = false
    self.logged_in_enabled = true
    services = sidebar_link_sections.find { |section| section.fetch(:title) == "Services" }

    assert services, "a signed-in customer reaches /build and /packages from the sidebar"
    assert_equal [ "/build", "/packages", "/integrations" ], services.fetch(:links).map { |link| link.fetch(:href) }
    assert_equal "App Builder", services.fetch(:links).first.fetch(:label)
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

    assert_equal ["Build", "NFL", "Services", "Apps"], sidebar_link_sections.map { |section| section.fetch(:title) }
  end

  # Alex McRitchie, 2026-11-04: "I don't see a purpose for /dashboard"; Applications and
  # Agents "are viewable from the admin dashboard"; Tasks "we can drop as Devops is a
  # better version". They leave every list; their routes stay.
  test "the Studio section leaves the sidebar and /links, and the four dropped pages are in no list" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    assert_equal [ "NFL", "Directory", "Services", "Apps" ], public_link_sections.map { |section| section.fetch(:title) }
    refute_includes sidebar_link_sections.map { |section| section.fetch(:title) }, "Studio"

    every_list = sidebar_link_sections + public_link_sections + admin_link_sections + basement_link_sections
    hrefs = every_list.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:href) }
    assert_includes hrefs, "/deployments", "control: these are an admin's lists"
    assert_empty hrefs & [ "/dashboard", "/applications", "/agents", "/tasks" ]
    assert_empty sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link.fetch(:href) } &
                 [ "/builders", "/news", "/contents", "/model_pipeline", "/body-archetypes", "/videos" ]
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
    assert_equal %w[Account Build], sidebar_link_sections.map { |section| section.fetch(:title) }
    build = sidebar_link_sections.last.fetch(:links)
    assert_equal [ "Chat", "Portfolio" ], build.map { |link| link.fetch(:label) }
    assert_equal "/chat", build.first.fetch(:href)
    assert_includes build.first.fetch(:emoji), "/agents/alex.webp"
    assert_equal "💬", build.first.fetch(:hover_emoji)
    assert sidebar_link_sections.flat_map { |section| section.fetch(:links) }.none? { |link| link.key?(:desc) }, "a visitor's link is one line"

    self.logged_in_enabled = true
    self.current_user = nil
    refute sidebar_link_sections.any? { |section| section[:title] == "Account" }
    refute sidebar_link_sections.flat_map { |section| section.fetch(:links) }.any? { |link| link[:href] == "/signin" }
    assert_equal [ "Chat", "Portfolio" ], signed_in_build_links
    assert_equal 1, sidebar_link_sections.count { |section| section[:title] == "Build" }

    self.admin_enabled = true
    assert_equal [ "Chat", "Portfolio" ], signed_in_build_links, "an admin is signed in, so an admin has them too"
    assert_equal 1, sidebar_link_sections.count { |section| section[:title] == "Build" }
    refute public_link_sections.any? { |section| section[:title] == "Build" }, "/links does not change"
  end

  private

  attr_accessor :admin_enabled, :logged_in_enabled, :current_user

  def basement_links
    basement_link_sections.flat_map { |section| section.fetch(:links) }
  end

  def signed_in_build_links
    sidebar_link_sections.find { |section| section[:title] == "Build" }.fetch(:links).map { |link| link.fetch(:label) }
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
  # [component] The owner section (AppOwnership.sidebar_links): first in the
  # sidebar, at most two apps by name and All apps third, every row swapping to a
  # rocket; absent for a signed-in user who owns nothing and for a visitor.
  test "[component] an owner's sidebar opens with up to two apps, and All apps third for three or more" do
    owner = User.create!(email: "sidebar-owner@example.com", name: "Sidebar Owner", role: "viewer")
    cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse", emoji: "🐉", color: "#DC2626", position: 5)
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    self.admin_enabled = false
    self.logged_in_enabled = true
    self.current_user = owner

    first = sidebar_link_sections.first
    assert_equal "Your apps", first.fetch(:title)
    assert_equal [ [ "Turf Monster", "/applications/turf-monster" ] ],
                 first.fetch(:links).map { |link| [ link.fetch(:label), link.fetch(:href) ] }
    assert first.fetch(:links).all? { |link| link[:hover_emoji] == "🚀" }

    AppMembership.create!(app: cyvasse, user: owner)
    assert_equal 2, sidebar_link_sections.first.fetch(:links).size
    assert_not_includes sidebar_link_sections.first.fetch(:links).map { |link| link.fetch(:label) }, "All apps"

    AppMembership.create!(app: apps(:mcritchie_studio), user: owner)
    links = sidebar_link_sections.first.fetch(:links)
    assert_equal 3, links.size
    assert_equal [ "All apps", "/applications" ], links.last.values_at(:label, :href)
    assert links.all? { |link| link[:hover_emoji] == "🚀" }

    self.current_user = User.create!(email: "sidebar-none@example.com", name: "No Apps", role: "viewer")
    assert_equal [ "Build", "NFL", "Services", "Apps" ], sidebar_link_sections.map { |section| section.fetch(:title) }

    self.logged_in_enabled = false
    self.current_user = nil
    refute sidebar_link_sections.any? { |section| section.fetch(:title) == "Your apps" }
  end
end
