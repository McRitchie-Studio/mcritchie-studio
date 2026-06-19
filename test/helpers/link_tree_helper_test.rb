require "test_helper"

class LinkTreeHelperTest < ActiveSupport::TestCase
  include LinkTreeHelper

  test "sidebar links include hover emoji transitions" do
    self.admin_enabled = true

    links = sidebar_link_sections.flat_map { |section| section.fetch(:links) }

    assert links.any? { |link| link[:label] == "Turf Monster" && link[:hover_emoji].present? }
    assert links.all? { |link| link[:hover_emoji].present? }, "expected every sidebar link to define hover_emoji"
  end

  private

  attr_accessor :admin_enabled

  def admin?
    !!admin_enabled
  end

  def logged_in?
    false
  end

  def dashboard_path = "/dashboard"
  def agents_path = "/agents"
  def tasks_path = "/tasks"
  def news_index_path = "/news"
  def contents_path = "/contents"
  def nfl_hub_path = "/nfl"
  def games_season_path(year) = "/games/#{year}"
  def teams_path = "/teams"
  def people_path = "/people"
  def docs_path = "/docs"
  def admin_signing_requests_path = "/admin/signing_requests"
  def admin_dashboard_path = "/admin"
  def admin_theme_path = "/admin/theme"
  def admin_schema_path = "/admin/schema"
  def devops_path = "/devops"
  def toast_test_path = "/toast_test"
  def admin_tiktok_connect_path = "/admin/tiktok/connect"
  def admin_ai_builder_multiple_path = "/admin/ai_builder_multiple"
  def workflow_news_index_path = "/news/workflow"
  def merge_people_path = "/people/merge"
  def duplicates_people_path = "/people/duplicates"
end
