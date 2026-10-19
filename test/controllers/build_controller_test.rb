require "test_helper"

# [integration] The /build funnel through real requests: a signed-out visitor's
# first message opens the chat with Ray, the draft survives the sign-in detour
# (by the magic link's return_to AND by the Google path that always lands on the
# home page), Build my app on a finished checklist queues the build, and a draft
# is only ever visible to the account that finished it. The chat itself:
# test/integration/build_intake_flow_test.rb.
class BuildControllerTest < ActionDispatch::IntegrationTest
  PROMPT = "A league site with schedules, scores and standings".freeze

  def send_prompt(text = PROMPT)
    post build_path, params: { app_request: { prompt: text } }
    AppRequest.recent.first
  end

  # The four taps, written as BuildIntake::Choice would write them.
  def complete_intake!(draft, subdomain: "league-hub")
    draft.reload.update!(answers: { "idea" => "A league site" }, cto_name: "Coach", cto_avatar: "harbor", subdomain: subdomain,
                         palette: { "name" => "Pitch",
                                    "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
                                    "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } })
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

  test "sending a prompt signed out saves a draft and opens the chat with Ray, no sign-in yet" do
    draft = send_prompt

    assert_redirected_to build_request_path(draft.token)
    assert draft.draft?
    assert_nil draft.user
    follow_redirect!
    assert_select "[data-test='build-chat-page']"
    assert_select "[data-test='build-register']", 0
    assert_select "[data-test='cto-chat-sent']", text: PROMPT
  end

  test "the page's first message answers in place: the draft's chat streams over the empty thread and the address moves, no redirect" do
    get build_path
    assert_select "#build-chat-page form#build-first-form[action='/build']"
    assert_select "##{BuildController::GALLERY_ID}", 1

    proof = BrowserProof.new(BuildController::PROOF_PURPOSE).issue(5.seconds.ago).reverse
    post build_path, params: { app_request: { prompt: PROMPT, form_proof: proof } }, as: :turbo_stream
    draft = AppRequest.recent.first

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action='replace'][target='build-chat-page'] template" do
      assert_select "[data-test='build-chat-page'][data-build-chat-poll-url='/build/#{draft.token}/turns']"
      assert_select "[data-test='build-turn'][data-pending='true'] [data-test='cto-chat-sent']", text: PROMPT
      assert_select "form#build-chat-form[action='/build/#{draft.token}/messages']"
    end
    assert_select "turbo-stream[action='replace'][target='build-checklist'] template [data-test='build-heading']", 1,
                  "no card yet, so the heading stays: a visitor may only be saying hi"
    assert_select "turbo-stream[action='replace_url'][url='/build/#{draft.token}']", 1
    # Once chatting there is no gallery, in place or on a reload: the two pages agree.
    assert_select "turbo-stream[action='remove'][target='#{BuildController::GALLERY_ID}']", 1
    assert draft.draft?
    get build_request_path(draft.token)
    assert_select "##{BuildController::GALLERY_ID}, [data-test='build-gallery']", 0
  end

  test "a refused first message comes back in the same box, with the reason and the text kept" do
    post build_path, params: { app_request: { prompt: "x" * (AppRequest::PROMPT_LIMIT + 1) } }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_select "turbo-stream[action='replace'][target='build-first-form'] template" do
      assert_select "[data-test='build-form-error']"
      assert_select "textarea[name='app_request[prompt]']", text: "x" * (AppRequest::PROMPT_LIMIT + 1)
    end
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

  test "the draft survives an emailed sign-in link and lands back in the chat" do
    draft = send_prompt
    user = users(:viewer)

    sign_in_through_email_link(user, build_request_path(draft.token))
    assert_redirected_to build_request_path(draft.token)
    follow_redirect!

    assert_select "[data-test='build-chat-page']"
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

  test "Build my app on a finished checklist launches the app and moves to its new CTO's chat" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)
    complete_intake!(draft)

    assert_difference [ -> { Task.count }, -> { App.count }, -> { AppCto.count }, -> { AgentMessage.where(soul_slug: "client_cto").count } ], 1 do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" } }
    end
    assert_redirected_to chat_application_path("league-hub")
    assert_response :see_other
    assert draft.reload.queued?
    assert AppOwnership.manage_app?(users(:viewer).reload, "league-hub"), "the requester owns the new app"
    cto = App.find_by!(slug: "league-hub").client_cto
    assert_equal [ "Coach", "harbor", "#15803D" ], [ cto.name, cto.portrait, cto.light["primary"] ]
    assert_equal "#15803D", App.find_by!(slug: "league-hub").theme_colors.dig("light", "primary")

    follow_redirect!
    assert_response :success
    assert_select "[data-test='agent-shell'][data-shell='app'] [data-test='agent-caption']", text: /Coach\s+· CTO of League Hub/
    assert_select "[data-test='agent-portrait'][style*='view-transition-name: agent-portrait'] [data-test='client-cto-portrait'][src*='cto_portraits/harbor']"
    assert_select "[data-test='cto-chat-head'][data-client-cto='true'] h1", text: "League Hub"
    assert_select "[data-test='devops-stage'][data-stage='building'][data-state='live']", 1, "the new build task is designed: Building, live"
    assert_select "[data-test='cto-chat-handover']", text: /Ray\s+Meet Coach, your CTO. I'll hand you over./
    # The CTO's opening message is there on arrival: code wrote it, no model ran, nothing is typing.
    assert_select "[data-test='cto-chat-turn'] [data-test='cto-chat-handover'] ~ [data-test='cto-chat-reply']", text: /Hi Viewer, I'm Coach, the agent who'll be managing League Hub\./
    assert_select "[data-test='cto-chat-typing']", 0
    assert_select "meta[name='view-transition'][content='same-origin']"

    # The card the claim opened is what an agent builds from: it asks for the
    # footer and names the SOP, after the requester's own words.
    devops = Task.find_by!(slug: draft.task_slug).metadata.fetch("devops")
    assert_includes devops.fetch("acceptance"), "league-hub.mcritchie.studio's home page renders the site footer (footer[data-site-footer])"
    assert_includes devops.fetch("agent_context"), "docs/agents/modules/launch-build-queue.md"
    assert_includes devops.fetch("agent_context"), "CTO: Coach (portrait harbor)"
    assert_equal [ "league-hub" ], devops.fetch("repositories")
  end

  test "Build my app on a checklist whose colours do not read is refused and launches nothing" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)
    complete_intake!(draft)
    draft.update_columns(palette: draft.palette.merge("dark" => draft.palette["dark"].except("accent")))

    assert_no_difference [ -> { Task.count }, -> { App.count } ] do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" } }
    end
    assert_redirected_to build_request_path(draft.token)
    assert_match(/Theme/, flash[:alert])
    assert draft.reload.draft?
  end

  test "a refused name re-renders the chat with the reason, and queues nothing" do
    draft = send_prompt
    log_in_as users(:viewer)
    get build_request_path(draft.token)
    complete_intake!(draft)

    assert_no_difference -> { Task.count } do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "www" } }
    end
    assert_response :unprocessable_entity
    assert_match(/reserved/, flash[:alert])
    assert_select "[data-test='build-chat-page']"
    assert draft.reload.draft?
  end

  # The summary card's turn, as Ray's last answer carries it.
  def summary_turn!(draft)
    AgentMessage.create!(channel: "web", external_id: "build:#{draft.token}:summary", channel_ref: "build",
                         thread_key: BuildIntake.thread_key(draft.token), soul_slug: BuildIntake.soul, content: "Let's use it.",
                         status: "completed", completed_at: Time.current, response_text: "Here's your app.", intake_card: { "card" => "summary" })
  end

  def with_vibe_apps_limit(limit, &)
    config = WorkspacePackage.config
    config["packages"].find { |pkg| pkg["key"] == "vibe" }["apps_per_account"] = limit
    WorkspacePackage.stub(:config, config, &)
  end

  test "[integration] a free-plan owner over the plan's limit gets the refusal ON the summary card, with their app and the plans, as a stream" do
    viewer = users(:viewer)
    log_in_as viewer
    first = send_prompt("A checkers game")
    get build_request_path(first.token)
    complete_intake!(first, subdomain: "first-checkers")
    patch build_request_path(first.token), params: { app_request: { subdomain: "first-checkers" } }
    assert_redirected_to chat_application_path("first-checkers")

    draft = send_prompt
    get build_request_path(draft.token)
    complete_intake!(draft)
    card = summary_turn!(draft)

    with_vibe_apps_limit(1) do
      assert_no_difference [ -> { App.count }, -> { Task.count } ] do
        patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" }, message_id: card.id }, as: :turbo_stream
      end
    end
    assert_response :unprocessable_content
    assert_equal "text/vnd.turbo-stream.html", response.media_type, "a stream, never a page Turbo would morph"
    assert_select "turbo-stream[action='replace'][target='#{BuildController.summary_dom_id(card)}'] template" do
      assert_select "[data-test='build-card-summary'][data-refused='true'][data-ready='true']"
      assert_select "[data-test='build-summary-refusal'][role='alert']" do
        assert_select "[data-test='build-summary-refusal-reason']", "Your Vibe plan includes 1 app, and you already have one."
        assert_select "a[data-test='build-summary-existing-app'][href='/applications/first-checkers/chat']"
        assert_select "a[data-test='build-summary-upgrade'][href='/packages']"
      end
      assert_select "[data-test='build-summary-build']", 1, "Build My App stays, to try again"
    end
    assert draft.reload.draft?
  end

  test "[integration] with the data's unlimited tier the same owner launches a second app" do
    log_in_as users(:viewer)
    first = send_prompt("A checkers game")
    get build_request_path(first.token)
    complete_intake!(first, subdomain: "first-checkers")
    patch build_request_path(first.token), params: { app_request: { subdomain: "first-checkers" } }

    draft = send_prompt
    get build_request_path(draft.token)
    complete_intake!(draft)
    patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" }, message_id: summary_turn!(draft).id }, as: :turbo_stream
    assert_response :success
    assert_select "turbo-stream[action='replace'][targets='#{BuildController::LAUNCH_TARGETS}'] template [data-test='build-launch'][data-app='league-hub']"
  end

  # Task build-launch-handoff: the launch happens on the server FIRST; the stream
  # only presents it. The shell is swapped in place for the launch panel, and the
  # address moves to the CTO's chat at once, so a reload mid-animation lands there.
  test "[integration] Build My App from the summary card launches, then answers with the launch panel over the shell and the address on the CTO's chat" do
    log_in_as users(:viewer)
    draft = send_prompt
    get build_request_path(draft.token)
    complete_intake!(draft)
    card = summary_turn!(draft)

    assert_difference [ -> { App.count }, -> { AppCto.count }, -> { Task.count } ], 1 do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" }, message_id: card.id }, as: :turbo_stream
    end
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert draft.reload.queued?, "launched before the panel is drawn"
    assert_select "turbo-stream[action='replace'][targets='[data-agent-shell]'] template" do
      assert_select "build-launch#build-launch[data-test='build-launch'][data-href='/applications/league-hub/chat']" do
        assert_select "[data-test='build-launch-portrait'][style*='view-transition-name: agent-portrait'] [data-test='client-cto-portrait'][src*='cto_portraits/harbor']"
        assert_select "[data-test='build-launch-caption']", text: /Coach\s+· CTO of League Hub/
        assert_select "[data-test='build-launch-app']", text: "League Hub"
        assert_select "[data-test='build-launch-step']", 3
      end
      assert_select "[data-test='build-launch'][style*='--cto-primary-light: 21 128 61;']", 1, "the app's own colours"
    end
    assert_select "turbo-stream[action='replace_url'][target='#{BuildController::LAUNCH_ID}'][url='/applications/league-hub/chat']"

    # A reload mid-animation is a plain visit to the chat: the CTO is already speaking.
    get chat_application_path("league-hub")
    assert_response :success
    assert_select "[data-test='cto-chat-reply']", text: /Hi Viewer, I'm Coach, the agent who'll be managing League Hub\./
    assert_select "[data-test='cto-chat-typing']", 0
  end

  test "[integration] the launch replay is an admin's, in development only" do
    refute Rails.application.routes.url_helpers.respond_to?(:build_launch_demo_path), "no route outside development"
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/build/launch-demo/league-hub") }
  end

  test "[integration] a name taken after the tap is refused on the card with a next step; without a card the composer says why" do
    log_in_as users(:viewer)
    draft = send_prompt
    get build_request_path(draft.token)
    complete_intake!(draft)
    card = summary_turn!(draft)
    App.create!(slug: "league-hub", name: "League Hub", emoji: "🏟", color: "#22C55E")

    assert_no_difference -> { Task.count } do
      patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" }, message_id: card.id }, as: :turbo_stream
    end
    assert_response :unprocessable_content
    assert_select "turbo-stream[target='#{BuildController.summary_dom_id(card)}'] template [data-test='build-summary-refusal']" do
      assert_select "[data-test='build-summary-refusal-reason']", /That name is taken\./
      assert_select "[data-test='build-summary-next']", /another address/
      assert_select "[data-test='build-summary-upgrade']", 0
    end

    patch build_request_path(draft.token), params: { app_request: { subdomain: "league-hub" } }, as: :turbo_stream
    assert_response :unprocessable_content
    assert_select "turbo-stream[action='replace'][target='#{BuildController::FORM_ID}'] template [data-test='cto-chat-error']", /That name is taken/
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
    complete_intake!(draft)
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

  test "an admin can queue several apps; each is a showcase and the list can filter them" do
    log_in_as users(:alex)
    # Unregistered names: the real showcase apps' subdomains are reserved by their
    # config/satellites.yml rows (register-showcase-apps).
    %w[coin-toss chess-club].each do |name|
      post build_path, params: { app_request: { prompt: "Rebuild #{name}" } }
      token = AppRequest.recent.first.token
      patch build_request_path(token), params: { app_request: { subdomain: name } }
      assert AppRequest.find_by(token: token).queued?, "#{name} should queue for an admin"
    end

    get build_requests_path(status: "showcase")
    assert_select "[data-test='app-request']", 2
    assert_select "[data-test='app-request-showcase']", 2
  end

  test "the /build page shows showcase apps once they are live" do
    live = AppRequest.create!(prompt: "A coin toss tournament. Call it in the air.", user: users(:alex)).queue!("coin-toss")
    live.update!(status: "live")

    get build_path
    assert_select "[data-test='build-example'][href='https://coin-toss.mcritchie.studio']", text: /Coin Toss/
    assert_select "[data-test='build-example']", text: /A coin toss tournament\./
  end

  test "the availability check answers in JSON" do
    get build_check_path, params: { subdomain: "WWW" }
    assert_equal({ "subdomain" => "www", "available" => false, "reason" => "That name is reserved." }, response.parsed_body)

    get build_check_path, params: { subdomain: "fresh-idea" }
    assert_equal true, response.parsed_body["available"]
  end

  # [integration] An app requested by a reader who came from an email is
  # credited to that email.
  test "an app request after arriving from an email credits it" do
    broadcast = Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    delivery = broadcast.deliveries.create!(contact: Contact.create!(email: "b-#{SecureRandom.hex(3)}@example.com"))

    get build_path(ref: delivery.token)
    send_prompt

    assert_equal ["requested_app"], delivery.events.of_kind("converted").map { |e| e.data["goal"] }
  end

  test "an app request with no email behind it credits nothing" do
    get build_path
    send_prompt
    assert_equal 0, EmailEvent.count
  end

  # [integration] Review follow-ups (PR #1655).
  test "the email's credit is used once, then the ref is forgotten" do
    broadcast = Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    delivery = broadcast.deliveries.create!(contact: Contact.create!(email: "c-#{SecureRandom.hex(3)}@example.com"))

    get build_path(ref: delivery.token)
    send_prompt
    assert_nil session[:email_ref], "a later visitor on this browser is not the email's reader"
    assert_equal 1, delivery.events.of_kind("converted").count
  end

  test "a crediting error still saves the draft and logs it" do
    broadcast = Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    delivery = broadcast.deliveries.create!(contact: Contact.create!(email: "d-#{SecureRandom.hex(3)}@example.com"))
    get build_path(ref: delivery.token)

    EmailEvents::Results.stub(:record_unsafely!, ->(*, **) { raise "db down" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_difference -> { AppRequest.count }, 1 do
          post build_path, params: { app_request: { prompt: PROMPT } }
        end
      end
    end
    assert_response :redirect
  end
end
