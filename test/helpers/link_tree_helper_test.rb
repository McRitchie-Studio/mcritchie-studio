require "test_helper"

class LinkTreeHelperTest < ActiveSupport::TestCase
  include LinkTreeHelper

  test "sidebar links include hover emoji transitions" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    assert links.any? { |link| link[:label] == "Turf Monster" && link[:hover_emoji].present? }
    assert links.all? { |link| link[:hover_emoji].present? }, "expected every sidebar link to define hover_emoji"
  end

  test "admin sidebar starts with site admin links and omits removed devops page" do
    self.admin_enabled = true

    sections = sidebar_link_sections
    links = sections.flat_map { |section| section.fetch(:links) }

    assert_equal "Site", sections.first.fetch(:title)
    assert sections.first.fetch(:admin)
    assert_equal ["Dashboard", "Deployments", "Theme", "Design System", "Schema", "Emails", "Link preview", "Assets"], sections.first.fetch(:links).map { |link| link.fetch(:label) }
    refute links.any? { |link| link[:href] == "/devops" || link[:label] == "DevOps" }
  end

  # The adoption of the engine's standard email page: the sidebar points at the
  # shared /admin/emails, not the retired /admin/email_images fork. Asserted on
  # the href because the label alone would still pass if the link were repointed.
  test "admin sidebar links the shared emails page, not the retired image page" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    emails = links.find { |link| link[:label] == "Emails" }

    assert emails, "the Site section should carry an Emails link"
    assert_equal "/admin/emails", emails.fetch(:href)
    refute links.any? { |link| link[:href] == "/admin/email_images" }
  end

  # task hub-adopts-link-preview: the engine's site-identity page (studio-engine
  # 0.82) is reached from the hub's own admin menu. The second assertion pins the
  # stubbed href to the route the engine actually draws in this app.
  test "admin sidebar links the engine link preview page" do
    self.admin_enabled = true

    preview = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.find { |link| link[:label] == "Link preview" }

    assert_equal "/admin/link_preview", preview&.fetch(:href)
    assert_equal "/admin/link_preview", Rails.application.routes.url_helpers.admin_link_preview_path
  end

  test "admin sidebar links the object store browser" do
    self.admin_enabled = true

    assets = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.find { |link| link[:label] == "Assets" }

    assert_equal "/assets", assets&.fetch(:href)
    assert_equal "/assets", Rails.application.routes.url_helpers.asset_browser_path
  end

  # task contacts-admin-page: the mailing list sits beside the broadcasts sent to it.
  test "admin sidebar has an Email section with Broadcasts then Contacts" do
    self.admin_enabled = true

    email = sidebar_link_sections.find { |section| section[:title] == "Email" }

    assert email&.fetch(:admin), "expected an admin Email section"
    assert_equal [ "/broadcasts", "/contacts", "/broadcasts/analytics" ], email.fetch(:links).map { |link| link.fetch(:href) }
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
  test "the Studio section links the model pipeline board" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    models = public_link_sections.flat_map { |section| section.fetch(:links) }
                                 .find { |link| link[:label] == "Models" }

    assert models, "expected a Models link in the Studio section"
    assert_equal "/model_pipeline", models.fetch(:href)
    assert models[:hover_emoji].present?
  end

  test "public (non-admin) sidebar omits the Activities admin link" do
    self.admin_enabled = false

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    refute links.any? { |link| link[:label] == "Activities" }
  end

  # [component] The engine's living style guide (/admin/style) is reachable from
  # the admin sidebar, and the engine-provided route resolves in this host app.
  test "admin sidebar exposes the Design System page link" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    design_system = links.find { |link| link[:label] == "Design System" }

    assert design_system, "expected a Design System link in the admin sidebar"
    assert_equal admin_style_path, design_system.fetch(:href)
    assert_equal "🎨", design_system.fetch(:emoji)
    assert design_system.fetch(:hover_emoji).present?, "expected a hover_emoji on the Design System link"

    # The canonical /admin/style route is bundled by studio-engine (0.18+) — confirm
    # it resolves here. The legacy /admin/design_system route still 301-redirects.
    assert_equal "/admin/style", Rails.application.routes.url_helpers.admin_style_path
  end

  test "admin sidebar links Deployments to the deploy lane board" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    deployments = links.find { |link| link[:label] == "Deployments" }

    assert deployments, "expected an admin Deployments link"
    assert_equal deployments_path, deployments.fetch(:href)
  end

  test "public sidebar omits the admin Deployments link" do
    self.admin_enabled = false

    labels = sidebar_link_sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:label] }

    refute_includes labels, "Deployments"
  end

  test "logged-out sidebar shows only the public sections" do
    self.admin_enabled = false
    self.logged_in_enabled = false

    sections = sidebar_link_sections

    assert_equal ["NFL", "Services", "Apps"], sections.map { |section| section.fetch(:title) }
    labels = sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:label] }
    refute_includes labels, "Dashboard"
    refute_includes labels, "Agents"
    refute_includes labels, "Builders"
    refute_includes labels, "Teams"
    refute_includes labels, "People"
  end

  test "the App Builder and the packages page are linked for everyone, signed in or not" do
    self.admin_enabled = false
    [ false, true ].each do |signed_in|
      self.logged_in_enabled = signed_in
      services = sidebar_link_sections.find { |section| section.fetch(:title) == "Services" }

      assert services, "customers must reach /build and /packages without an account (signed_in=#{signed_in})"
      assert_equal [ "/build", "/packages" ], services.fetch(:links).map { |link| link.fetch(:href) }
      assert_equal "App Builder", services.fetch(:links).first.fetch(:label)
    end
  end

  test "admins get a Clients section: app requests, stack and credentials" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    clients = sidebar_link_sections.find { |section| section.fetch(:title) == "Clients" }

    assert clients, "admins should see a Clients section"
    assert clients[:admin], "Clients is an admin section"
    assert_equal [ "/build/requests", "/stack", "/credentials" ], clients.fetch(:links).map { |link| link.fetch(:href) }
  end

  test "non-admins never see the Clients section" do
    self.admin_enabled = false
    self.logged_in_enabled = true

    refute sidebar_link_sections.any? { |section| section.fetch(:title) == "Clients" }
  end

  test "a signed-in non-admin sees only the public sections" do
    self.admin_enabled = false
    self.logged_in_enabled = true

    assert_equal ["NFL", "Services", "Apps"], sidebar_link_sections.map { |section| section.fetch(:title) }
  end

  test "the admin's link hub reveals Studio with Agents and Builders together" do
    self.admin_enabled = true
    self.logged_in_enabled = true

    sections = public_link_sections
    studio = sections.find { |section| section.fetch(:title) == "Studio" }

    assert studio, "expected a Studio section for admins"
    labels = studio.fetch(:links).map { |link| link.fetch(:label) }
    assert_includes labels, "Agents"
    assert_includes labels, "Builders"
    assert_equal labels.index("Agents") + 1, labels.index("Builders"),
      "Builders should sit right after Agents"
    other_titles = sections.reject { |section| section.fetch(:title) == "Studio" }.map { |section| section.fetch(:title) }
    assert_equal ["NFL", "Directory", "Services", "Apps"], other_titles
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

  private

  attr_accessor :admin_enabled, :logged_in_enabled

  def admin?
    !!admin_enabled
  end

  def logged_in?
    !!logged_in_enabled
  end

  def dashboard_path = "/dashboard"
  def agents_path = "/agents"
  def builders_path = "/builders"
  def tasks_path = "/tasks"
  def news_index_path = "/news"
  def contents_path = "/contents"
  # ADDING A LINK TO LinkTreeHelper MEANS ADDING ITS STUB HERE. This class is an
  # ActiveSupport::TestCase and includes the helper directly, so no route helper is
  # defined for it — a new link raises NameError in EVERY test in this file, which is how
  # the Models link took CI red on 2026-09-27 while the page itself was green.
  def model_pipeline_path = "/model_pipeline"
  def broadcasts_path = "/broadcasts"
  def contacts_path = "/contacts"
  def broadcast_analytics_path = "/broadcasts/analytics"
  def nfl_hub_path = "/nfl"
  def games_season_path(year) = "/games/#{year}"
  def teams_path = "/teams"
  def people_path = "/people"
  def docs_path = "/docs"
  def packages_path = "/packages"
  def build_path = "/build"
  def build_requests_path = "/build/requests"
  def stack_path = "/stack"
  def credentials_path = "/credentials"
  def deployments_path = "/deployments"
  def admin_dashboard_path = "/admin"
  def admin_theme_path = "/admin/theme"
  def admin_style_path = "/admin/style"
  def admin_design_system_path = "/admin/design_system"
  def admin_schema_path = "/admin/schema"
  def admin_emails_path = "/admin/emails"
  def admin_link_preview_path = "/admin/link_preview"
  def asset_browser_path = "/assets"
  def admin_tiktok_connect_path = "/admin/tiktok/connect"
  def activities_agents_path = "/agents/activities"
  def admin_ai_builder_multiple_path = "/admin/ai_builder_multiple"
  def workflow_news_index_path = "/news/workflow"
  def merge_people_path = "/people/merge"
  def duplicates_people_path = "/people/duplicates"
  def alt_videos_path = "/alt_videos"
end
