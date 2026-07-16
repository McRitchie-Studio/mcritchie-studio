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
    assert_equal ["Dashboard", "Deployments", "Theme", "Schema", "Email images"], sections.first.fetch(:links).map { |link| link.fetch(:label) }
    refute links.any? { |link| link[:href] == "/devops" || link[:label] == "DevOps" }
  end

  test "admin sidebar includes the Activities feed link" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }
    activities = links.find { |link| link[:label] == "Activities" }

    assert activities, "expected an Activities link in the admin sidebar"
    assert_equal "🎭", activities[:emoji]
    assert_equal "/agents/activities", activities[:href]
  end

  test "public (non-admin) sidebar omits the Activities admin link" do
    self.admin_enabled = false

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    refute links.any? { |link| link[:label] == "Activities" }
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

  test "logged-out sidebar shows only the public Apps section" do
    self.admin_enabled = false
    self.logged_in_enabled = false

    sections = sidebar_link_sections

    assert_equal ["Apps"], sections.map { |section| section.fetch(:title) }
    labels = sections.flat_map { |section| section.fetch(:links) }.map { |link| link[:label] }
    refute_includes labels, "Dashboard"
    refute_includes labels, "Agents"
    refute_includes labels, "Builders"
  end

  test "logged-in sidebar reveals Studio with Agents and Builders together" do
    self.admin_enabled = false
    self.logged_in_enabled = true

    sections = sidebar_link_sections
    studio = sections.find { |section| section.fetch(:title) == "Studio" }

    assert studio, "expected a Studio section for signed-in users"
    labels = studio.fetch(:links).map { |link| link.fetch(:label) }
    assert_includes labels, "Agents"
    assert_includes labels, "Builders"
    assert_equal labels.index("Agents") + 1, labels.index("Builders"),
      "Builders should sit right after Agents"
    other_titles = sections.reject { |section| section.fetch(:title) == "Studio" }.map { |section| section.fetch(:title) }
    assert_equal ["NFL", "Directory", "Apps"], other_titles
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
  def nfl_hub_path = "/nfl"
  def games_season_path(year) = "/games/#{year}"
  def teams_path = "/teams"
  def people_path = "/people"
  def docs_path = "/docs"
  def admin_signing_requests_path = "/admin/signing_requests"
  def deployments_path = "/deployments"
  def admin_dashboard_path = "/admin"
  def admin_theme_path = "/admin/theme"
  def admin_schema_path = "/admin/schema"
  def admin_email_images_path = "/admin/email_images"
  def toast_test_path = "/toast_test"
  def admin_tiktok_connect_path = "/admin/tiktok/connect"
  def activities_agents_path = "/agents/activities"
  def admin_ai_builder_multiple_path = "/admin/ai_builder_multiple"
  def workflow_news_index_path = "/news/workflow"
  def merge_people_path = "/people/merge"
  def duplicates_people_path = "/people/duplicates"
end
