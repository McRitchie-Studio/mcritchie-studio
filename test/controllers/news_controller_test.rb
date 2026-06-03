require "test_helper"

class NewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @new_article = news(:new_article)
    @reviewed_article = news(:reviewed_article)
    @processed_article = news(:processed_article)
    @refined_article = news(:refined_article)
    @concluded_article = news(:concluded_article)
  end

  # === HTML page tests ===

  test "index renders news page" do
    get news_index_path
    assert_response :success
    assert_select "h2", "News Pipeline"
  end

  test "show renders news detail" do
    get news_path(@new_article.slug)
    assert_response :success
  end

  test "workflow renders workflow page" do
    get workflow_news_index_path
    assert_response :success
    assert_select "h2", "News Workflow"
  end

  # === Kanban stage moves via JSON PATCH ===

  test "move news to any stage via PATCH JSON" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "reviewed" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "reviewed", @new_article.stage
    assert_not_nil @new_article.reviewed_at
  end

  test "move news backwards via PATCH JSON" do
    log_in_as(@admin)
    patch news_path(@concluded_article.slug, format: :json),
          params: { news: { stage: "new" } }, as: :json
    assert_response :success
    @concluded_article.reload
    assert_equal "new", @concluded_article.stage
  end

  test "move news to processed sets processed_at" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "processed" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "processed", @new_article.stage
    assert_not_nil @new_article.processed_at
  end

  test "move news to refined sets refined_at" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "refined" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "refined", @new_article.stage
    assert_not_nil @new_article.refined_at
  end

  test "move news to concluded sets concluded_at" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "concluded" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "concluded", @new_article.stage
    assert_not_nil @new_article.concluded_at
  end

  test "move news to archived sets archived_at" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "archived" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "archived", @new_article.stage
    assert_not_nil @new_article.archived_at
  end

  # === Archive action ===

  test "archive works via JSON" do
    log_in_as(@admin)
    post archive_news_path(@new_article.slug, format: :json)
    assert_response :success
    @new_article.reload
    assert_equal "archived", @new_article.stage
  end

  # === Delete ===

  test "delete works via JSON" do
    log_in_as(@admin)
    assert_difference "News.count", -1 do
      delete news_path(@new_article.slug, format: :json)
    end
    assert_response :no_content
  end

  # === Update fields via JSON ===

  test "update title via JSON returns JSON not redirect" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { title: "Updated Title" } }, as: :json
    assert_response :success
    @new_article.reload
    assert_equal "Updated Title", @new_article.title
  end

  # === Auth enforcement ===

  test "moves require admin" do
    log_in_as(@viewer)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "reviewed" } }, as: :json
    assert_response :redirect
  end

  test "moves require login" do
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "reviewed" } }, as: :json
    # Format-aware auth (OPSEC-046): AJAX/JSON gets a clean 401, not an HTML redirect.
    assert_response :unauthorized
  end

  # === JSON requests work without CSRF token ===

  test "JSON PATCH works without CSRF token" do
    log_in_as(@admin)
    patch news_path(@new_article.slug, format: :json),
          params: { news: { stage: "reviewed" } }, as: :json
    assert_response :success
  end

  # === Reorder ===

  test "reorder sets positions in order" do
    log_in_as(@admin)
    n1 = News.create!(title: "Reorder A", stage: "new")
    n2 = News.create!(title: "Reorder B", stage: "new")

    post reorder_news_index_path(format: :json),
         params: { slugs: [n2.slug, n1.slug] }, as: :json
    assert_response :success

    n1.reload
    n2.reload
    assert_equal 100, n1.position
    assert_equal 200, n2.position
  end

  test "reorder requires admin" do
    log_in_as(@viewer)
    post reorder_news_index_path(format: :json),
         params: { slugs: [@new_article.slug] }, as: :json
    assert_response :redirect
  end

  test "reorder requires login" do
    post reorder_news_index_path(format: :json),
         params: { slugs: [@new_article.slug] }, as: :json
    assert_response :unauthorized
  end

  # === Review ===

  test "review updates fields and advances stage" do
    log_in_as(@admin)
    post review_news_path(@new_article.slug), params: {
      primary_person: "Lionel Messi",
      primary_team: "Inter Miami",
      primary_action: "signed",
      secondary_person: "David Beckham",
      secondary_team: "Barcelona"
    }
    assert_redirected_to news_path(@new_article.slug)
    @new_article.reload
    assert_equal "reviewed", @new_article.stage
    assert_equal "Lionel Messi", @new_article.primary_person
    assert_equal "Inter Miami", @new_article.primary_team
    assert_equal "signed", @new_article.primary_action
    assert_equal "David Beckham", @new_article.secondary_person
    assert_equal "Barcelona", @new_article.secondary_team
  end

  test "review requires new stage" do
    log_in_as(@admin)
    post review_news_path(@reviewed_article.slug), params: {
      primary_person: "Test", primary_team: "Test", primary_action: "test"
    }
    assert_redirected_to news_path(@reviewed_article.slug)
    @reviewed_article.reload
    assert_equal "reviewed", @reviewed_article.stage
  end

  test "review requires login" do
    post review_news_path(@new_article.slug), params: {
      primary_person: "Test", primary_team: "Test", primary_action: "test"
    }
    assert_response :redirect
    @new_article.reload
    assert_equal "new", @new_article.stage
  end

  # === Process step ===

  test "process_step generates slugs for reviewed article" do
    log_in_as(@admin)
    post process_step_news_path(@reviewed_article.slug)
    assert_redirected_to news_path(@reviewed_article.slug)
    @reviewed_article.reload
    assert_equal "processed", @reviewed_article.stage
    assert_equal "christian-pulisic", @reviewed_article.primary_person_slug
    assert_equal "usa", @reviewed_article.primary_team_slug
  end

  test "process_step rejects non-reviewed article" do
    log_in_as(@admin)
    post process_step_news_path(@new_article.slug)
    assert_redirected_to news_path(@new_article.slug)
    @new_article.reload
    assert_equal "new", @new_article.stage
  end

  test "process_step requires admin" do
    log_in_as(@viewer)
    post process_step_news_path(@reviewed_article.slug)
    assert_response :redirect
  end

  # === Refine ===

  test "refine requires processed stage" do
    log_in_as(@admin)
    post refine_news_path(@new_article.slug)
    assert_redirected_to news_path(@new_article.slug)
    @new_article.reload
    assert_equal "new", @new_article.stage
  end

  test "refine requires login" do
    post refine_news_path(@processed_article.slug)
    assert_response :redirect
    @processed_article.reload
    assert_equal "processed", @processed_article.stage
  end

  test "refine requires admin" do
    log_in_as(@viewer)
    post refine_news_path(@processed_article.slug)
    assert_response :redirect
  end

  # === Conclude ===

  test "conclude requires refined stage" do
    log_in_as(@admin)
    post conclude_news_path(@new_article.slug)
    assert_redirected_to news_path(@new_article.slug)
    @new_article.reload
    assert_equal "new", @new_article.stage
  end

  test "conclude requires login" do
    post conclude_news_path(@refined_article.slug)
    assert_response :redirect
    @refined_article.reload
    assert_equal "refined", @refined_article.stage
  end

  test "conclude requires admin" do
    log_in_as(@viewer)
    post conclude_news_path(@refined_article.slug)
    assert_response :redirect
  end
end
