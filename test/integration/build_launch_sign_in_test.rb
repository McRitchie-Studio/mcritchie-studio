require "test_helper"

# [integration] A signed-out Build My App (tasks build-launch-sign-in, Alex
# 2026-10-18, and build-sign-in-modal, 2026-10-19): /build stays public, the
# press opens the sign-in MODAL (an open_modal Turbo Stream, nothing added to the
# thread) and remembers itself in this browser's session
# (BuildIntake::PendingLaunch); every press does both again, so a dismissed
# modal reopens. The sign-in, by the emailed link or by Google, lands the
# visitor on the app they were building: the draft claimed, the launch run once,
# then /applications/:slug/chat, whose first visit plays the launch panel once
# (AppCto launch_animation_pending). Nothing launches without that session's
# press: not a forwarded link in another browser, not a refresh, not a stale
# press, and never someone else's draft; a press whose draft is gone is dropped.
class BuildLaunchSignInTest < ActionDispatch::IntegrationTest
  PROMPT = "A league site with schedules, scores and standings".freeze
  PALETTE = { "name" => "Pitch",
              "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
              "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }.freeze

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  # A signed-out draft with every step set, and Ray's summary card in its thread.
  def ready_draft!(subdomain: "league-hub")
    post build_path, params: { app_request: { prompt: PROMPT } }
    draft = AppRequest.recent.first
    draft.update!(answers: { "idea" => "A league site", "title" => "League Hub" }, cto_name: "Coach", cto_avatar: "harbor",
                  subdomain: subdomain, palette: PALETTE)
    card = AgentMessage.create!(channel: "web", external_id: "build:#{draft.token}:summary", channel_ref: "build",
                                thread_key: BuildIntake.thread_key(draft.token), soul_slug: BuildIntake.soul, content: "Let's use it.",
                                status: "completed", completed_at: Time.current, response_text: "Here's your app.",
                                intake_card: { "card" => "summary" })
    [ draft, card ]
  end

  def press_build_my_app(draft, card)
    patch build_request_path(draft.token), params: { app_request: { subdomain: draft.subdomain }, message_id: card.id }, as: :turbo_stream
  end

  # The prompt's email form: the request it makes, then the emailed link, consumed.
  def sign_in_by_email(email, return_to)
    post "/magic_link", params: { email: email, return_to: return_to }, as: :json
    link = Studio::Link.where(kind: "magic_link").order(:created_at).last
    assert_equal return_to, link.metadata["return_to"]
    post link_consume_path(token: link.token)
  end

  # The landing's answer to a fresh launch: the app's chat, whose first visit is
  # the launch panel (build/_launch), which plays its steps and then visits the
  # same chat. The flag is spent, so the next visit is the chat itself.
  def assert_launch_panel_for(slug)
    assert_redirected_to chat_application_path(slug)
    follow_redirect!
    assert_response :success
    assert_select "[data-test='build-launch-landing'] [data-test='build-launch'][data-app='#{slug}'][data-href='#{chat_application_path(slug)}']", 1
    assert_not AppCto.find_by!(app_slug: slug).launch_animation_pending?
    get chat_application_path(slug)
    assert_response :success
    assert_select "[data-test='build-launch']", 0, "a refresh after the panel is the chat"
    assert_select "[data-test='cto-chat-page'][data-app='#{slug}']", 1
  end

  # The stream a signed-out press answers with: it opens the engine's auth modal,
  # returning to the launch landing, and names the address.
  def assert_opens_sign_in_modal(draft, host: "league-hub.mcritchie.studio")
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type, "a stream, never the old silent redirect"
    streams = css_select("turbo-stream")
    assert_equal 1, streams.size, "one stream: nothing is added to the thread"
    stream = streams.first
    assert_equal [ "open_modal", "auth" ], [ stream["action"], stream["modal"] ]
    props = JSON.parse(stream["props"])
    assert_equal({ "returnTo" => "/build/#{draft.token}/launch", "title" => "Sign in to build your app",
                   "subtitle" => "Free. Then we start building #{host}." }, props)
  end

  def mock_google(email)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{email.hash.abs}", info: { email: email, name: "Jordan Builder" }
    )
  end

  test "signed out, Build My App opens the sign-in modal and binds the press; the draft stays, and every later press opens it again" do
    draft, card = ready_draft!

    assert_no_difference [ -> { App.count }, -> { Task.count }, -> { AgentMessage.count } ] do
      press_build_my_app(draft, card)
    end
    assert_opens_sign_in_modal(draft)
    assert draft.reload.draft?
    assert_nil draft.user
    first = session[BuildIntake::PendingLaunch::KEY]
    assert_equal [ draft.token, "league-hub" ], first.values_at("token", "subdomain")

    # Dismissed (nothing reaches the server), then pressed again: the same modal,
    # and the press bound afresh, so its hour starts again.
    travel 10.minutes do
      press_build_my_app(draft, card)
      assert_opens_sign_in_modal(draft)
      assert_operator session[BuildIntake::PendingLaunch::KEY]["at"], :>, first["at"], "the press is bound afresh"
    end
    assert draft.reload.draft?
  end

  test "the modal names the address the press carried, held to one DNS label" do
    draft, card = ready_draft!

    patch build_request_path(draft.token), params: { app_request: { subdomain: "x" * 80 }, message_id: card.id }, as: :turbo_stream
    assert_opens_sign_in_modal(draft, host: "#{'x' * 63}.mcritchie.studio")
    assert_equal 63, session[BuildIntake::PendingLaunch::KEY]["subdomain"].length
  end

  test "without Turbo the signed-out press still binds and returns to the draft" do
    draft, card = ready_draft!

    patch build_request_path(draft.token), params: { app_request: { subdomain: draft.subdomain }, message_id: card.id }
    assert_redirected_to build_request_path(draft.token)
    assert_equal draft.token, session[BuildIntake::PendingLaunch::KEY]["token"]
  end

  test "the magic link signs in, claims the draft, launches it once and the app's first visit plays the launch panel; a refresh only reopens the app" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)

    sign_in_by_email("new-builder@example.test", build_request_launch_path(draft.token))
    assert_redirected_to build_request_launch_path(draft.token)
    assert_difference [ -> { App.count }, -> { AppCto.count }, -> { Task.count } ], 1 do
      follow_redirect!
    end
    assert_launch_panel_for("league-hub")
    assert_select "[data-test='cto-chat-reply']", { text: /Hi there, I'm Coach/ }, "a new account has no name yet"
    user = User.find_by!(email: "new-builder@example.test")
    assert_equal user, draft.reload.user, "claimed by the new session"
    assert_equal "queued", draft.status
    assert AppMembership.exists?(app_slug: "league-hub", user_slug: user.slug, role: "owner")
    assert_nil session[BuildIntake::PendingLaunch::KEY], "the press is spent"

    assert_no_difference [ -> { App.count }, -> { Task.count } ] do
      get build_request_launch_path(draft.token)
    end
    assert_redirected_to chat_application_path("league-hub"), "a refresh goes to the app and launches nothing"
  end

  test "Google lands on home, which forwards to the launch, whose app's first visit plays the launch panel" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)
    mock_google("google-builder@example.test")

    get "/auth/google_oauth2/callback"
    assert_redirected_to root_path
    follow_redirect!
    assert_redirected_to build_request_launch_path(draft.token)
    assert_difference -> { App.count }, 1 do
      follow_redirect!
    end
    assert_launch_panel_for("league-hub")
    assert_equal "google-builder@example.test", draft.reload.user.email

    get root_path
    assert_response :success, "the forward happens once"
  end

  test "a forwarded link opened in another browser has no press: it reaches the draft and launches nothing" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)

    other = open_session
    token = Studio::Link.create_magic_link(email: "elsewhere@example.test", return_to: build_request_launch_path(draft.token)).token
    assert_no_difference [ -> { App.count }, -> { Task.count } ] do
      other.post link_consume_path(token: token)
      other.follow_redirect!
    end
    assert_equal "/build/#{draft.token}", other.response.location&.then { |l| URI(l).path }
    assert_nil draft.reload.user, "the landing itself claims nothing"
    assert draft.draft?
  end

  test "a press for a draft someone else has since claimed is refused, and their draft is left alone" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)
    owner = User.create!(email: "owner@example.test", name: "Owner")
    draft.update!(user: owner)

    sign_in_by_email("intruder@example.test", build_request_launch_path(draft.token))
    assert_no_difference -> { App.count } do
      follow_redirect!
    end
    assert_redirected_to build_path
    assert_equal owner, draft.reload.user
    assert draft.draft?
  end

  test "a press abandoned for over an hour launches nothing after a later sign-in" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)

    travel BuildIntake::PendingLaunch::TTL + 1.minute do
      sign_in_by_email("late@example.test", build_request_launch_path(draft.token))
      assert_no_difference -> { App.count } do
        follow_redirect!
      end
      assert_redirected_to build_request_path(draft.token)
    end
  end

  test "signed out, the landing asks for sign-in and keeps the press for after it" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)

    get build_request_launch_path(draft.token)
    assert_response :redirect
    assert_not_equal chat_application_path("league-hub"), URI(response.location).path
    assert_equal draft.token, session[BuildIntake::PendingLaunch::KEY]["token"], "nothing was taken"
    assert_equal 0, App.where(slug: "league-hub").count
  end

  test "a launch refused after sign-in lands on the draft with the reason on its summary card" do
    draft, card = ready_draft!
    press_build_my_app(draft, card)
    App.create!(slug: "league-hub", name: "League Hub", emoji: "🏟", color: "#22C55E")

    sign_in_by_email("unlucky@example.test", build_request_launch_path(draft.token))
    assert_no_difference -> { Task.count } do
      follow_redirect!
    end
    assert_redirected_to build_request_path(draft.token)
    follow_redirect!
    assert_response :success
    assert_select "##{BuildController.summary_dom_id(card)}[data-refused='true']" do
      assert_select "[data-test='build-summary-refusal-reason']", /That name is taken\./
      assert_select "[data-test='build-summary-next']", /another address/
    end
    assert draft.reload.draft?
    assert_equal "unlucky@example.test", draft.user.email, "the draft is theirs now, to fix and press again"

    get build_request_path(draft.token)
    assert_select "[data-test='build-summary-refusal']", 0, "the reason shows once"
  end

  test "signed in, Build My App launches at once, binds no press, and the app's first visit plays the launch panel" do
    draft, card = ready_draft!
    log_in_as users(:viewer)

    patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" }, message_id: card.id }, as: :turbo_stream
    assert_equal users(:viewer), draft.reload.user
    assert_nil session[BuildIntake::PendingLaunch::KEY]
    assert_launch_panel_for("league-hub")
  end

  test "a press whose draft was deleted, launched, or claimed by someone else is dropped at the landing: home never bounces to /build" do
    { deleted: ->(d) { d.destroy! },
      claimed: ->(d) { d.update!(user: User.create!(email: "taker-#{d.id}@example.test", name: "Taker")) },
      launched: ->(d) { d.update_columns(status: "queued") } }.each do |how, change|
      reset!
      draft, card = ready_draft!(subdomain: "league-#{how}")
      press_build_my_app(draft, card)
      change.call(draft)
      mock_google("google-#{how}@example.test")

      get "/auth/google_oauth2/callback"
      follow_redirect!
      assert_response :success, "#{how}: the home page, not a forward"
      assert_nil session[BuildIntake::PendingLaunch::KEY], "#{how}: the press is forgotten"
      get root_path
      assert_response :success, "#{how}: and stays forgotten"
    end
  end

  test "the landing never launches by GET without the press, even for the draft's own signed-in owner" do
    draft, = ready_draft!
    log_in_as users(:viewer)

    assert_no_difference -> { App.count } do
      get build_request_launch_path(draft.token)
    end
    assert_redirected_to build_request_path(draft.token)
  end
end
