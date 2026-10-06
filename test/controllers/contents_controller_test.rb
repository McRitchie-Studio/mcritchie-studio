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

  # The workflow <select> is hand-maintained, so a value added to
  # Content::WORKFLOWS without a matching option is invisible until someone
  # saves — no option is `selected`, the browser submits the first, and
  # :workflow is permitted on update. On a game_recap that also disarms the
  # [game_slug, workflow] idempotency index. content-pipeline.md's "Form
  # gotcha" states the rule; this is what enforces it.
  test "the edit form offers every Content::WORKFLOWS value" do
    log_in_as(@admin)
    get edit_content_path(@idea_content.slug)
    assert_response :success

    offered = css_select("select[name='content[workflow]'] option").map { |option| option["value"] }

    Content::WORKFLOWS.each do |workflow|
      assert_includes offered, workflow,
                      "#{workflow} is in Content::WORKFLOWS but missing from the edit form's " \
                      "workflow select — saving the form would silently rewrite it to the first option"
    end
  end

  # === Video Post (X): the team that won and the MP4 in, an approved post out ===

  X_CREDS = %w[X_API_KEY X_API_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET].freeze

  def stub_video_store(&block)
    Content::AttachVideo.stub(:store, ->(key:, body:) { "https://cdn.test/#{key}" }, &block)
  end

  # Every ESPN read the draft makes, answered for the Bills: 3-1, won at 17:00Z on the
  # latest day that carries no prime-time tag (#mnf, #tnf), so the caption reads the same any day.
  def stub_espn(won: true)
    kickoff = 1.day.ago.utc
    kickoff -= 1.day while kickoff.monday? || kickoff.thursday?
    Content::DraftXCopy.fetch = lambda do |url|
      case url
      when %r{/teams\z}     then { "sports" => [{ "leagues" => [{ "teams" => [{ "team" => { "id" => "2", "displayName" => "Buffalo Bills" } }] }] }] }
      when %r{/teams/2\z}   then { "team" => { "record" => { "items" => [{ "summary" => "3-1" }] } } }
      when %r{/schedule\z}
        { "events" => [{ "date" => kickoff.strftime("%Y-%m-%dT17:00Z"), "shortName" => "NE @ BUF",
                         "competitions" => [{ "status" => { "type" => { "completed" => true } }, "competitors" => [
                           { "winner" => won, "score" => { "displayValue" => "27" }, "team" => { "id" => "2" } },
                           { "winner" => !won, "score" => { "displayValue" => "20" }, "team" => { "id" => "17", "displayName" => "New England Patriots" } }
                         ] }] }] }
      end
    end
    yield
  ensure
    Content::DraftXCopy.fetch = nil
  end

  def with_x_keys
    prior = X_CREDS.to_h { |k| [k, ENV[k]] }
    X_CREDS.each { |k| ENV[k] = "test" }
    yield
  ensure
    prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def ready_video_post(**attrs)
    Content.create!({ title: "Bills win", workflow: "video_post_x", stage: "script", team_slug: "buffalo-bills",
                      captions: "Bills 3-1 #nfl #nflfootball #billsmafia #buffalo #bills <b>",
                      final_video_url: "https://cdn.test/v.mp4",
                      game_facts: { "record" => "3-1", "source" => "ESPN (test)", "exceptions" => [],
                                    "last_final" => { "matchup" => "NE @ BUF", "score" => "27-20", "won" => true } } }.merge(attrs))
  end

  def create_video_post(team: "buffalo-bills", file: fixture_file_upload("video_post.mp4", "video/mp4"))
    post contents_path, params: { content: { workflow: "video_post_x", team_slug: team, video_file: file }.compact }
  end

  test "new content form offers Video Post (X) with a team picker and a file field" do
    log_in_as(@admin)
    get new_content_path

    assert_response :success
    assert_select "form[enctype='multipart/form-data']"
    assert_select "option[value='video_post_x']", "Video Post (X)"
    assert_select "[data-test='video-post-x-fields'] select[data-test='video-post-x-team'] option[value='buffalo-bills']"
    assert_select "[data-test='video-post-x-fields'] input[type=file][accept='video/mp4']"
    # Both are live on this workflow alone: off it the file is not uploaded, and
    # the second team_slug field (Starter Post) is the one that steps aside here.
    assert_equal 2, response.body.scan(%(:disabled="workflow !== &#39;video_post_x&#39;")).size
    assert_includes response.body, %(:disabled="workflow === &#39;video_post_x&#39;")
  end

  test "creating a video post stores the MP4, drafts the copy and lands ready for approval" do
    log_in_as(@admin)
    teams(:buffalo_bills).update!(hashtag: "#BillsMafia")

    stub_video_store do
      stub_espn do
        assert_difference -> { Content.where(workflow: "video_post_x").count }, 1 do
          create_video_post
        end
      end
    end

    content = Content.where(workflow: "video_post_x").order(:created_at).last
    assert_redirected_to content_path(content.slug)
    assert_equal "Bills win", content.title
    assert_equal "script", content.stage
    assert_equal "buffalo-bills", content.team_slug
    assert_equal "https://cdn.test/video_posts/#{content.slug}.mp4", content.final_video_url
    assert_equal "Bills 3-1 #nfl #nflfootball #billsmafia #buffalo #bills", content.captions
  end

  test "a draft that fails does not fail the create: the card waits with a Draft button" do
    log_in_as(@admin)
    Content::DraftXCopy.fetch = ->(_url) { raise X::PostDraft::Error, "could not read ESPN" }

    stub_video_store { assert_difference(-> { Content.count }, 1) { create_video_post } }
    content = Content.where(workflow: "video_post_x").order(:created_at).last
    get content_path(content.slug)

    assert_equal "idea", content.stage
    assert_select "[data-test='video-post-x-draft-error']", /could not read ESPN/
    assert_select "[data-test='video-post-x-redraft']"
    assert_select "[data-test='video-post-x-post']", 0
  ensure
    Content::DraftXCopy.fetch = nil
  end

  test "a video post with no MP4, a file that is not one, or no team creates no card" do
    log_in_as(@admin)

    stub_video_store do
      assert_no_difference -> { Content.count } do
        create_video_post(file: nil)
        assert_response :unprocessable_entity
        assert_includes response.body, "Attach the MP4 to post."

        create_video_post(file: fixture_file_upload("video_post.txt", "text/plain"))
        assert_response :unprocessable_entity
        assert_includes response.body, "That file is not an MP4."

        create_video_post(team: "")
        assert_response :unprocessable_entity
        assert_includes response.body, "Pick the team that won."
      end
    end
  end

  test "a failed upload leaves no card behind for a soul to claim" do
    log_in_as(@admin)

    Content::AttachVideo.stub(:store, ->(**) { raise "bucket down" }) do
      assert_no_difference(-> { Content.count }) { create_video_post }
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "bucket down"
  end

  test "an existing card cannot be edited into a video post, which would have no video" do
    log_in_as(@admin)
    patch content_path(@idea_content.slug), params: { content: { workflow: "video_post_x" } }

    assert_equal "video", @idea_content.reload.workflow
  end

  test "the card draws the post as X will: tags in blue, copy escaped, video inline, facts beneath" do
    content = ready_video_post
    log_in_as(@admin)
    get content_path(content.slug)

    assert_select "[data-test='video-post-x-card'][data-state='script']"
    assert_select "[data-test='x-post-preview']", /Turf Monster/
    assert_select "[data-test='x-post-preview'] video[src='https://cdn.test/v.mp4'][playsinline]"
    assert_select "[data-test='x-post-preview-text'] span[style*='#1d9bf0']", "#billsmafia"
    assert_select "[data-test='x-post-preview-text'] span[style*='#1d9bf0']", 5
    assert_select "[data-test='x-post-preview-text'] b", 0, "copy must be escaped, never rendered as markup"
    assert_includes response.body, "&lt;b&gt;"
    assert_select "[data-test='x-post-weight']", /\A\s*59 of 280/
    assert_select "[data-test='video-post-x-facts']", /Record 3-1 read from ESPN \(test\);\s+last final NE @ BUF 27-20 \(win\)/
    assert_select "[data-test='video-post-x-status']", "Ready for your approval"
  end

  test "the Post button is on only when the server holds the X keys, and says why when off" do
    content = ready_video_post
    log_in_as(@admin)

    get content_path(content.slug)
    assert_select "button[data-test='video-post-x-post'][disabled]"
    assert_select "[data-test='video-post-x-refusal']", /the X keys are not set on this server/

    with_x_keys do
      get content_path(content.slug)
      assert_select "button[data-test='video-post-x-post']:not([disabled])"
      assert_select "[data-test='video-post-x-refusal']", 0
    end
  end

  test "a visitor sees the preview and none of the controls" do
    content = ready_video_post
    get content_path(content.slug)

    assert_select "[data-test='x-post-preview']"
    assert_select "[data-test='video-post-x-post']", 0
    assert_select "[data-test='video-post-x-redraft']", 0
    assert_select "[data-test='video-post-x-copy-field']", 0
  end

  test "exceptions from the draft are shown above the button" do
    content = ready_video_post(game_facts: { "record" => "3-1", "source" => "ESPN (test)",
                                             "exceptions" => ["ESPN's most recent final for Buffalo Bills is a LOSS"] })
    log_in_as(@admin)
    get content_path(content.slug)

    assert_select "[data-test='video-post-x-exception']", /Check before posting: ESPN's most recent final for Buffalo Bills is a LOSS/
  end

  test "Post queues one job, shows the card posting, and a second click posts nothing more" do
    content = ready_video_post(captions: "Bills 3-1 #nfl")
    log_in_as(@admin)

    with_x_keys do
      assert_enqueued_jobs 1, only: ContentPostVideoToXJob do
        post post_video_to_x_content_path(content.slug)
        post post_video_to_x_content_path(content.slug)
      end
      assert_match(/Not posted: a post is already in flight/, flash[:alert])

      get content_path(content.slug)
      assert_select "[data-test='video-post-x-status']", "Posting…"
      assert_select "[data-test='video-post-x-card'][x-init*='reload']"
      assert_select "[data-test='video-post-x-post']", 0
    end
  end

  test "Post without the keys posts nothing and says so" do
    content = ready_video_post(captions: "Bills 3-1 #nfl")
    log_in_as(@admin)

    assert_no_enqueued_jobs(only: ContentPostVideoToXJob) { post post_video_to_x_content_path(content.slug) }
    assert_match(/Not posted: the X keys are not set/, flash[:alert])
    assert_equal "script", content.reload.stage
  end

  test "only an admin can post, redraft or settle" do
    content = ready_video_post
    log_in_as(@viewer)

    assert_no_enqueued_jobs(only: ContentPostVideoToXJob) { post post_video_to_x_content_path(content.slug) }
    post draft_x_copy_content_path(content.slug)
    post resolve_x_post_content_path(content.slug)
    assert_equal "script", content.reload.stage
    assert_equal "Bills 3-1 #nfl #nflfootball #billsmafia #buffalo #bills <b>", content.captions
  end

  test "Redraft rewrites the copy from the live record" do
    content = ready_video_post(captions: "old copy")
    teams(:buffalo_bills).update!(hashtag: "#BillsMafia")
    log_in_as(@admin)

    stub_espn { post draft_x_copy_content_path(content.slug) }

    assert_equal "Bills 3-1 #nfl #nflfootball #billsmafia #buffalo #bills", content.reload.captions
  end

  test "a posted card shows the link and what X read back, and no controls" do
    content = ready_video_post(stage: "posted", post_url: "https://x.com/turfmonstershow/status/123",
                               game_facts: { "post" => { "state" => "posted", "verified" => { "video" => true, "seconds" => 27.7 } } })
    log_in_as(@admin)
    get content_path(content.slug)

    assert_select "a.break-all[data-test='video-post-x-link'][href='https://x.com/turfmonstershow/status/123']"
    assert_select "[data-test='video-post-x-verified']", /video attached, 27.7s/
    assert_select "[data-test='video-post-x-post']", 0
    assert_select "[data-test='video-post-x-status']", "Posted"
  end

  test "a run that died mid-post asks the operator to look, then takes either answer" do
    stuck = { "post" => { "state" => "unknown", "attempted_at" => "2026-10-05T01:00:00Z", "error" => "timeout" } }
    content = ready_video_post(stage: "assembly", game_facts: stuck)
    log_in_as(@admin)

    get content_path(content.slug)
    assert_select "[data-test='video-post-x-stuck']", /may be live/
    assert_select "[data-test='video-post-x-stuck'] a[href='https://x.com/turfmonstershow']"
    assert_select "[data-test='video-post-x-post']", 0

    post resolve_x_post_content_path(content.slug), params: { post_url: "https://example.com/nope" }
    assert_equal "assembly", content.reload.stage

    post resolve_x_post_content_path(content.slug), params: { post_url: "https://x.com/turfmonstershow/status/456" }
    assert_equal "posted", content.reload.stage
    assert_equal "456", content.post_id

    other = ready_video_post(stage: "assembly", game_facts: stuck)
    post resolve_x_post_content_path(other.slug)
    assert_equal "script", other.reload.stage
  end

  test "settle refuses a card that is not stuck" do
    content = ready_video_post
    log_in_as(@admin)
    post resolve_x_post_content_path(content.slug), params: { post_url: "https://x.com/turfmonstershow/status/456" }

    assert_equal "script", content.reload.stage
    assert_nil content.post_url
  end

end
