require "test_helper"

# [integration] hub-security-gates-pass: a session-authenticated JSON write
# verifies the CSRF token like any other write.
#
# The attack each test replays: a page on a sibling site (a client app or a
# preview under *.mcritchie.studio) submits a plain HTML form to a hub `.json`
# route. The session cookie is SameSite=Lax and the sites are same-site, so the
# browser sends Alex's cookie; a form POST needs no CORS preflight; and
# Rack::MethodOverride turns `_method=patch` or `_method=delete` into the verb.
# The only thing the forging page cannot send is the token from the hub's own
# <meta name="csrf-token">, so the write must be refused without it.
#
# The control in each pair is the request the hub's own board sends: a fetch
# with a JSON body and X-CSRF-Token read from that meta tag. It must still land.
#
# The test environment turns forgery protection off (config/environments/test.rb),
# so every test here turns it on for its own duration.
class JsonWritesKeepCsrfTest < ActionDispatch::IntegrationTest
  # Sign in first: the magic-link consume is itself a form POST, and the session
  # it opens is the cookie the forging page rides on.
  setup do
    log_in_as(users(:alex))
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown { ActionController::Base.allow_forgery_protection = @forgery_was }

  # The token the hub's layout hands its own pages, read the way the board's
  # JavaScript reads it.
  def page_csrf_token(path)
    get path
    assert_response :success
    token = css_select("meta[name='csrf-token']").first&.[]("content")
    assert token.present?, "#{path} renders no csrf-token meta tag"
    token
  end

  # The board's own write: JSON body, JSON accept, the page's token.
  def board_headers(token)
    { "X-CSRF-Token" => token, "Accept" => "application/json" }
  end

  def assert_refused_as_forgery
    assert_response :unprocessable_content
  end

  # --- tasks -----------------------------------------------------------------

  test "a forged form PATCH to /tasks/<slug>.json is refused and the task keeps its stage" do
    task = tasks(:new_task)

    post "/tasks/#{task.slug}.json", params: { _method: "patch", task: { stage: "archived" } }

    assert_refused_as_forgery
    assert_equal "designed", task.reload.stage
  end

  test "control: the board's archive fetch with the page token still archives the task" do
    task = tasks(:new_task)
    token = page_csrf_token(tasks_path)

    patch "/tasks/#{task.slug}.json", params: { task: { stage: "archived" } },
                                      headers: board_headers(token), as: :json

    assert_response :success
    assert_equal "archived", task.reload.stage
  end

  test "a forged form DELETE to /tasks/<slug>.json is refused and the task survives" do
    task = tasks(:new_task)

    post "/tasks/#{task.slug}.json", params: { _method: "delete" }

    assert_refused_as_forgery
    assert Task.exists?(task.id)
  end

  # --- contents --------------------------------------------------------------

  test "a forged form DELETE to /contents/<slug>.json is refused and the content survives" do
    content = Content.create!(title: "Forged delete target", stage: "idea")

    post "/contents/#{content.slug}.json", params: { _method: "delete" }

    assert_refused_as_forgery
    assert Content.exists?(content.id)
  end

  test "control: the contents board's delete fetch with the page token still deletes" do
    content = Content.create!(title: "Board delete target", stage: "idea")
    token = page_csrf_token(contents_path)

    delete "/contents/#{content.slug}.json", headers: board_headers(token)

    assert_response :no_content
    refute Content.exists?(content.id)
  end

  # --- news ------------------------------------------------------------------

  test "a forged form POST to /news/<slug>/archive.json is refused and the story keeps its stage" do
    news = News.create!(title: "Forged archive target", stage: "new")

    post "/news/#{news.slug}/archive.json", params: { anything: "1" }

    assert_refused_as_forgery
    assert_equal "new", news.reload.stage
  end

  test "control: the news board's archive fetch with the page token still archives" do
    news = News.create!(title: "Board archive target", stage: "new")
    token = page_csrf_token(news_index_path)

    post "/news/#{news.slug}/archive.json", headers: board_headers(token), as: :json

    assert_response :success
    assert_equal "archived", news.reload.stage
  end

  # --- model pipeline --------------------------------------------------------

  test "a forged form PATCH to /model_pipeline/<slug>.json is refused and the look keeps its stage" do
    look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Forged move")
    stage = look.stage

    post "/model_pipeline/#{look.slug}.json", params: { _method: "patch", appearance: { stage: "generation" } }

    assert_refused_as_forgery
    assert_equal stage, look.reload.stage
  end

  test "control: the model pipeline board's move with the page token still moves the look" do
    look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Board move")
    token = page_csrf_token(model_pipeline_path)

    patch "/model_pipeline/#{look.slug}.json", params: { appearance: { stage: "generation" } },
                                               headers: board_headers(token), as: :json

    assert_response :success
    assert_equal "generation", look.reload.stage
  end

  # --- the bearer API --------------------------------------------------------

  # /api/v1 is ActionController::API behind a bearer token and carries no
  # session, so CSRF does not apply to it; turning protection on changes nothing.
  test "control: a bearer-token API write with no session and no CSRF token still lands" do
    reset!
    task = tasks(:new_task)
    bearer = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)

    patch api_v1_task_path(task.slug), params: { stage: "building" },
                                       headers: { "Authorization" => "Bearer #{bearer}" }, as: :json

    assert_response :success
    assert_equal "building", task.reload.stage
  end
end
