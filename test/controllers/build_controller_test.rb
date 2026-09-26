require "test_helper"

# [integration] The /build funnel through real requests: a signed-out visitor's
# prompt survives the sign-in detour (by the magic link's return_to AND by the
# Google path that always lands on the home page), claiming a name queues the
# build, and a draft is only ever visible to the account that finished it.
class BuildControllerTest < ActionDispatch::IntegrationTest
  PROMPT = "A league site with schedules, scores and standings".freeze

  def send_prompt(text = PROMPT)
    post build_path, params: { app_request: { prompt: text } }
    AppRequest.recent.first
  end

  def sign_in_through_email_link(user, return_to)
    # The request the /build sign-in step makes, then the link it emails.
    post "/magic_link", params: { email: user.email, return_to: return_to }, as: :json
    link = Studio::Link.where(kind: "magic_link").order(:created_at).last
    assert_equal return_to, link.metadata["return_to"], "the emailed link must carry the draft's address"
    post link_consume_path(token: link.token)
  end

  test "anyone can open /build without an account" do
    get build_path

    assert_response :success
    assert_select "[data-test='build-form'] textarea[name='app_request[prompt]']"
  end

  test "sending a prompt signed out saves a draft and asks the visitor to register" do
    draft = send_prompt

    assert_redirected_to build_request_path(draft.token)
    assert draft.draft?
    assert_nil draft.user
    follow_redirect!
    assert_select "[data-test='build-register']"
    assert_select "[data-test='build-echo']", text: PROMPT
  end

  test "the signed-out composer gets JSON back: the draft's token and path, for the sign-in modal" do
    post build_path, params: { app_request: { prompt: PROMPT } }, as: :json
    draft = AppRequest.recent.first

    assert_response :created
    assert_equal({ "token" => draft.token, "path" => build_request_path(draft.token) }, response.parsed_body)
    assert draft.draft?

    post build_path, params: { app_request: { prompt: " " } }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Prompt/, response.parsed_body["error"])
  end

  test "the prompt survives an emailed sign-in link and lands on the name step" do
    draft = send_prompt
    user = users(:viewer)

    sign_in_through_email_link(user, build_request_path(draft.token))
    assert_redirected_to build_request_path(draft.token)
    follow_redirect!

    assert_select "[data-test='build-claim']"
    assert_equal user, draft.reload.user, "signing in attaches the draft to its finisher"
  end

  test "Google sign-in lands on home, which forwards the visitor to their draft once" do
    draft = send_prompt
    log_in_as users(:viewer) # the session keeps the draft token across sign-in

    get root_path
    assert_redirected_to build_request_path(draft.token)

    get root_path
    assert_response :success, "the forward happens once, not on every visit home"
  end

  test "claiming a name queues the build and shows the status page" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)

    assert_difference -> { Task.count }, 1 do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" } }
    end
    assert_redirected_to build_request_path(draft.token)
    follow_redirect!

    assert_select "[data-test='build-status']"
    assert_select "[data-test='build-host']", text: "league-hub.mcritchie.studio"
    assert draft.reload.queued?
  end

  test "a refused name re-renders the name step with the reason, and queues nothing" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)

    assert_no_difference -> { Task.count } do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "www" } }
    end
    assert_response :unprocessable_entity
    assert_select "[data-test='build-errors']", text: /reserved/
    assert draft.reload.draft?
  end

  test "a draft that belongs to someone else is not shown" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token) # attaches it to viewer
    assert_equal users(:viewer), draft.reload.user

    log_in_as User.create!(email: "someone-else@example.test", name: "Someone Else")
    get build_request_path(draft.token)

    assert_redirected_to build_path
  end

  test "an admin opening an unsigned draft reads it without taking it" do
    draft = send_prompt
    log_in_as users(:alex)
    get build_request_path(draft.token)
    assert_response :success
    assert_nil draft.reload.user
  end

  test "a queued request's status page is private to its owner" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)
    patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" } }
    assert draft.reload.queued?

    # show's own draft guard does not run for a queued request, so this is the
    # load_request ownership check alone.
    log_in_as User.create!(email: "nosy@example.test", name: "Nosy Neighbour")
    get build_request_path(draft.token)
    assert_redirected_to build_path

    reset!
    get build_request_path(draft.token)
    assert_redirected_to build_path, "signed out, a queued request is not shown either"
  end

  test "the requests list is admin-only" do
    get build_requests_path
    assert_redirected_to "/login"

    log_in_as users(:viewer)
    get build_requests_path
    assert_redirected_to root_path
  end

  test "an admin sees every requested app, drafts behind their own tab" do
    AppRequest.create!(prompt: "A league site", user: users(:viewer)).queue!("league-hub")
    AppRequest.create!(prompt: "An unfinished idea")
    log_in_as users(:alex)

    get build_requests_path
    assert_response :success
    assert_select "[data-test='app-request']", 1, "the default tab is real requests, not drafts"
    assert_select "[data-test='app-request-host']", text: "league-hub.mcritchie.studio"
    assert_select "[data-test='app-request-prompt']", text: "A league site"
    assert_select "[data-test='app-request-task']"
    assert_select "[data-test='app-request-tab'][data-status='draft']", text: /Drafts\s*1/

    get build_requests_path(status: "draft")
    assert_select "[data-test='app-request'][data-status='draft']", 1

    get build_requests_path(status: "all")
    assert_select "[data-test='app-request']", 2
  end

  test "the availability check answers in JSON" do
    get build_check_path, params: { subdomain: "WWW" }
    assert_equal({ "subdomain" => "www", "available" => false, "reason" => "That name is reserved." }, response.parsed_body)

    get build_check_path, params: { subdomain: "fresh-idea" }
    assert_equal true, response.parsed_body["available"]
  end
end
