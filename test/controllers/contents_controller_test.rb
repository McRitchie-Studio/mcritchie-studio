require "test_helper"

class ContentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @idea_content = contents(:idea_content)
    @hook_content = contents(:hook_content)
    @script_content = contents(:script_content)
    @posted_content = contents(:posted_content)
  end

  # === HTML page tests ===

  test "index renders content page" do
    get contents_path
    assert_response :success
    assert_select "h2", "Content Pipeline"
  end

  test "index renders the studio board primitive with card and dropzone contract" do
    get contents_path
    assert_response :success
    # Rendered by the engine board primitive (studio/board/_board), not a hand-roll.
    assert_select "section[data-test='studio-board']"
    # The ZONE half of the identity contract — one dropzone per stage.
    assert_select "#dropzone-idea.kanban-dropzone[data-stage=?]", "idea"
    # Per-column count chip (gap 2 count_class colours it).
    assert_select "[data-board-count=?]", "idea"
    # The CARD half — id=card-<slug>, .kanban-card, data-slug, data-stage.
    card = css_select("#card-#{@idea_content.slug}.kanban-card").first
    assert card, "expected the content card to render via the board primitive"
    assert_equal @idea_content.slug, card["data-slug"]
    assert_equal "idea", card["data-stage"]
  end

  test "reorder persists and the board renders cards in the new order" do
    log_in_as(@admin)
    a = Content.create!(title: "Order One", stage: "idea")
    b = Content.create!(title: "Order Two", stage: "idea")

    post reorder_contents_path(format: :json),
         params: { slugs: [b.slug, a.slug] }, as: :json
    assert_response :success
    assert_operator b.reload.position, :>, a.reload.position

    get contents_path
    ids = css_select("#dropzone-idea .kanban-card").map { |el| el["id"] }
    assert_operator ids.index("card-#{b.slug}"), :<, ids.index("card-#{a.slug}"),
                    "expected the reordered card to render above its sibling"
  end

  test "show renders content detail" do
    get content_path(@idea_content.slug)
    assert_response :success
  end

  # === Create ===

  test "create new content idea" do
    log_in_as(@admin)
    assert_difference "Content.count", 1 do
      post contents_path, params: { content: { title: "New test idea", description: "Test description" } }
    end
    content = Content.last
    assert_equal "idea", content.stage
    assert_redirected_to content_path(content.slug)
  end

  test "create requires admin" do
    log_in_as(@viewer)
    assert_no_difference "Content.count" do
      post contents_path, params: { content: { title: "Should fail" } }
    end
    assert_response :redirect
  end

  test "create requires login" do
    assert_no_difference "Content.count" do
      post contents_path, params: { content: { title: "Should fail" } }
    end
    assert_response :redirect
  end

  # === Update ===

  test "update content via JSON" do
    log_in_as(@admin)
    patch content_path(@idea_content.slug, format: :json),
          params: { content: { title: "Updated Title" } }, as: :json
    assert_response :success
    @idea_content.reload
    assert_equal "Updated Title", @idea_content.title
  end

  # === Delete ===

  test "delete works" do
    log_in_as(@admin)
    assert_difference "Content.count", -1 do
      delete content_path(@idea_content.slug)
    end
    assert_redirected_to contents_path
  end

  test "delete requires admin" do
    log_in_as(@viewer)
    assert_no_difference "Content.count" do
      delete content_path(@idea_content.slug)
    end
    assert_response :redirect
  end

  # === Hook step ===

  test "hook_step advances idea to hook" do
    log_in_as(@admin)
    post hook_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "hook", @idea_content.stage
  end

  test "hook_step rejects non-idea content" do
    log_in_as(@admin)
    post hook_step_content_path(@hook_content.slug)
    assert_redirected_to content_path(@hook_content.slug)
    @hook_content.reload
    assert_equal "hook", @hook_content.stage
  end

  test "hook_step requires admin" do
    log_in_as(@viewer)
    post hook_step_content_path(@idea_content.slug)
    assert_response :redirect
  end

  # === Script step ===

  test "script_step advances hook to script" do
    log_in_as(@admin)
    post script_step_content_path(@hook_content.slug)
    assert_redirected_to content_path(@hook_content.slug)
    @hook_content.reload
    assert_equal "script", @hook_content.stage
  end

  test "script_step rejects non-hook content" do
    log_in_as(@admin)
    post script_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "idea", @idea_content.stage
  end

  # === Assets step ===

  test "assets_step advances script to assets" do
    log_in_as(@admin)
    post assets_step_content_path(@script_content.slug)
    assert_redirected_to content_path(@script_content.slug)
    @script_content.reload
    assert_equal "assets", @script_content.stage
  end

  test "assets_step rejects non-script content" do
    log_in_as(@admin)
    post assets_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "idea", @idea_content.stage
  end

  # === Assemble step ===

  test "assemble_step rejects non-assets content" do
    log_in_as(@admin)
    post assemble_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "idea", @idea_content.stage
  end

  # === Post step ===

  test "post_step rejects non-assembly content" do
    log_in_as(@admin)
    post post_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "idea", @idea_content.stage
  end

  # === Review step ===

  test "review_step advances posted to reviewed" do
    log_in_as(@admin)
    post review_step_content_path(@posted_content.slug), params: {
      views: 5000, likes: 200, comments_count: 30, shares: 50
    }
    assert_redirected_to content_path(@posted_content.slug)
    @posted_content.reload
    assert_equal "reviewed", @posted_content.stage
    assert_equal 5000, @posted_content.views
  end

  test "review_step rejects non-posted content" do
    log_in_as(@admin)
    post review_step_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    @idea_content.reload
    assert_equal "idea", @idea_content.stage
  end

  test "review_step requires login" do
    post review_step_content_path(@posted_content.slug)
    assert_response :redirect
    @posted_content.reload
    assert_equal "posted", @posted_content.stage
  end

  # === Kanban stage moves via JSON PATCH ===

  test "move content to any stage via PATCH JSON" do
    log_in_as(@admin)
    patch content_path(@idea_content.slug, format: :json),
          params: { content: { stage: "hook" } }, as: :json
    assert_response :success
    @idea_content.reload
    assert_equal "hook", @idea_content.stage
    assert_not_nil @idea_content.hooked_at
  end

  test "move content backwards via PATCH JSON" do
    log_in_as(@admin)
    patch content_path(@posted_content.slug, format: :json),
          params: { content: { stage: "idea" } }, as: :json
    assert_response :success
    @posted_content.reload
    assert_equal "idea", @posted_content.stage
  end

  # === Reorder ===

  test "reorder sets positions in order" do
    log_in_as(@admin)
    c1 = Content.create!(title: "Reorder A", stage: "idea")
    c2 = Content.create!(title: "Reorder B", stage: "idea")

    post reorder_contents_path(format: :json),
         params: { slugs: [c2.slug, c1.slug] }, as: :json
    assert_response :success

    c1.reload
    c2.reload
    assert_equal 100, c1.position
    assert_equal 200, c2.position
  end

  test "reorder requires admin" do
    log_in_as(@viewer)
    post reorder_contents_path(format: :json),
         params: { slugs: [@idea_content.slug] }, as: :json
    assert_response :redirect
  end

  # === News → Content bridge ===

  test "create_content from concluded news" do
    log_in_as(@admin)
    concluded = news(:concluded_article)
    assert_difference "Content.count", 1 do
      post create_content_news_path(concluded.slug)
    end
    content = Content.last
    assert_equal "idea", content.stage
    assert_equal "news", content.source_type
    assert_equal concluded.slug, content.source_news_slug
    assert_redirected_to content_path(content.slug)
  end

  test "create_content rejects non-concluded news" do
    log_in_as(@admin)
    post create_content_news_path(news(:new_article).slug)
    assert_redirected_to news_path(news(:new_article).slug)
    assert_equal "new", news(:new_article).stage
  end

  test "create_content requires login" do
    post create_content_news_path(news(:concluded_article).slug)
    assert_response :redirect
  end

  # === Starter Post (X) workflow ===

  test "create_starter_post_x creates a Content for the team and redirects to edit" do
    log_in_as(@admin)
    team = Team.where(league: "nfl").first
    skip "no NFL team fixture available" unless team

    assert_difference "Content.count", 1 do
      post starter_post_x_contents_path(team_slug: team.slug)
    end
    content = Content.order(:created_at).last
    assert_equal "starter_post_x", content.workflow
    assert_equal team.slug, content.team_slug
    assert_equal "script", content.stage
    assert_equal "studio", content.source_type
    assert_match(/lineup/i, content.captions.to_s)
    assert_redirected_to edit_content_path(content.slug)
  end

  test "create_starter_post_x without team_slug redirects to nfl-rosters" do
    log_in_as(@admin)
    post starter_post_x_contents_path
    assert_redirected_to nfl_rosters_path
  end

  test "create_starter_post_x requires admin" do
    post starter_post_x_contents_path(team_slug: "buffalo-bills")
    assert_response :redirect
  end

  test "generate_lineup_assets requires a lineup-graphic workflow" do
    log_in_as(@admin)
    post generate_lineup_assets_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    assert_match(/lineup-graphic workflows/, flash[:alert].to_s)
  end

  test "generate_lineup_assets requires admin" do
    post generate_lineup_assets_content_path(@idea_content.slug)
    assert_response :redirect
  end

  test "post_to_x requires starter_post_x workflow" do
    log_in_as(@admin)
    post post_to_x_content_path(@idea_content.slug)
    assert_redirected_to content_path(@idea_content.slug)
    assert_match(/starter_post_x/, flash[:alert].to_s)
  end
end
