require "test_helper"

# [integration] A signed-out visitor builds with Ritch through real requests: the
# first message (bot-shielded) starts a draft and Ritch's thread, Ritch's answers
# (completed here as bin/dispatcher would, with intake cards) render as cards,
# the status card appears once Start App locks the idea, and each tap after it
# fills its tiles in the order Ritch asks (Theme, Agent, Domain), and signing in adopts the request and Build queues it
# through the existing claim path. The Build control itself is Ritch's summary
# card's (build-cards-advance-chat); this test posts what it posts.
class BuildIntakeFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  IDEA = "A league site with schedules, scores and standings".freeze
  PALETTE = { "name" => "Pitch",
              "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
              "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }.freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  # The first message as the page sends it: the proof its script wrote, reversed.
  def first_message(text = IDEA, proof_age: 5.seconds)
    proof = BrowserProof.new(BuildController::PROOF_PURPOSE).issue(Time.current - proof_age).reverse
    post build_path, params: { app_request: { prompt: text, client_id: "first-0001", form_proof: proof } }
    AppRequest.recent.first
  end

  # Ritch's answer, as the dispatcher completes it.
  def ray_answers(text, card = nil)
    claim = AgentMessage.claim!(soul: "ray", worker: "mac-1")
    assert claim.message, "Ritch should have a message to answer"
    body = card ? "#{text}\n===PROPOSAL===\n#{card.to_json}" : text
    claim.message.complete!(worker: "mac-1", response_text: body)
    perform_enqueued_jobs(only: AgentMessageReplyJob)
    claim.message.reload
  end

  def say(request_row, text)
    post build_request_messages_path(request_row.token), params: { build_chat: { text: text, client_id: SecureRandom.uuid } },
                                                         as: :turbo_stream
    assert_response :success
  end

  def tap_card(request_row, field, **params)
    patch build_request_intake_path(request_row.token), params: { field: field, **params }, as: :turbo_stream
  end

  # A tap, and the visitor turn it relays: the stream appends it, pending, and
  # it is the next row the dispatcher claims for Ritch.
  def tap_and_relay(request_row, field, line, **params)
    tap_card(request_row, field, client_id: SecureRandom.uuid, **params)
    assert_response :success
    relay = AgentMessage.where(thread_key: BuildIntake.thread_key(request_row.token)).order(:id).last
    assert_equal line, relay.content
    assert_includes response.body, %(target="#{AgentMessages::WebChat::MESSAGES_TARGET}"), "#{field}: the relayed turn is appended"
    assert_includes response.body, %(id="build-turn-#{relay.id}")
    assert_includes response.body, %(data-pending="true"), "#{field}: the page polls for Ritch's answer"
    relay
  end

  test "a signed-out visitor goes from idea to Build My App by taps alone, then signs in and the app launches" do
    request_row = first_message
    assert_redirected_to build_request_path(request_row.token)
    first = AgentMessage.find_by!(thread_key: BuildIntake.thread_key(request_row.token))
    assert_equal %w[received ray public], [ first.status, first.soul_slug, first.person.role ]

    get build_request_path(request_row.token)
    assert_response :success
    assert_select "[data-test=build-chat-page]"
    assert_select "[data-test=build-turn][data-pending=true]", 1, "Ritch's answer is pending, so the page polls"
    assert_select "#build-checklist[data-card=false] [data-test=build-heading]", 1, "no card yet: the heading, not an empty form"
    assert_select "[data-test=build-my-app]", 0, "the status card carries no Build control"

    idea = ray_answers("Got it: a league site.",
                       { kind: "intake", card: "idea", title: "League Standings Hub", features: [ "Live standings", "Game schedules" ] })
    get build_request_turns_path(request_row.token), params: { ids: first.id }
    assert_response :success
    assert_includes response.body, "data-test=\"build-card-idea\""
    refute_includes response.body, "data-test=\"build-status-card\"", "an idea card alone does not bring the status card"
    assert_includes response.body, "data-test=\"build-heading\"", "the heading stays until Start App"
    assert_includes response.body, "League Standings Hub"
    get build_request_path(request_row.token)
    assert_select "[data-test=build-card-idea] [data-test=build-choose-idea]", "Start App"
    assert_select "[data-test=build-status-card]", 0

    # Start App: the idea locks, and the visitor's line goes to Ritch, who answers
    # with the THEME card. The status card waits for that card (Alex,
    # 2026-10-20): the tap's stream and every poll while Ritch types redraw the
    # heading, now naming the locked idea.
    relay = tap_and_relay(request_row, "idea", "Let's build League Standings Hub.", message_id: idea.id)
    assert_equal "League Standings Hub", request_row.reload.answers["title"]
    assert_equal "theme", request_row.next_intake_step, "the theme comes before the CTO"
    status = Nokogiri::HTML(response.body).css("turbo-stream[target=build-checklist] template").map(&:inner_html).join
    assert_select Nokogiri::HTML.fragment(status), "[data-test=build-status-card]", 0, "Start App alone does not bring the status card"
    assert_select Nokogiri::HTML.fragment(status), "#build-checklist[data-card=false][data-heading=locked] [data-test=build-heading-title]",
                  "League Standings Hub", "the heading names the locked idea while Ritch types"
    get build_request_turns_path(request_row.token), params: { ids: relay.id }
    refute_includes response.body, "data-test=\"build-status-card\"", "a poll while Ritch types keeps the heading"
    get build_request_path(request_row.token)
    assert_select "#build-checklist[data-heading=locked] [data-test=build-heading-title]", "League Standings Hub"
    assert_select "[data-test=build-status-card]", 0, "a reload while Ritch types shows the heading too"

    themes = ray_answers("Pick a theme.", { kind: "intake", card: "palette", palettes: [ PALETTE, PALETTE.merge("name" => "Pitch Two"), PALETTE.merge("name" => "Pitch Three") ] })
    assert_equal relay, themes, "the dispatcher claimed the relayed turn"
    # The poll that brings the theme card brings the status card in the same
    # response, so it pops in with the card, no reload.
    get build_request_turns_path(request_row.token), params: { ids: themes.id }
    assert_includes response.body, "data-test=\"build-card-palette\""
    status = Nokogiri::HTML(response.body).css("turbo-stream[target=build-checklist] template").map(&:inner_html).join
    assert_select Nokogiri::HTML.fragment(status), "[data-test=build-status-card] [data-test=build-status-title]", "League Standings Hub",
                  "the theme card's poll draws the status card, titled"
    get build_request_path(request_row.token)
    assert_select "#build-checklist[data-card=true] [data-test=build-status-card]", 1
    assert_select "[data-test=build-card-palette] [data-test=build-palette]", 3
    assert_select "[data-test=build-card-palette] input[name=index][value='1'][checked]", 1, "the middle theme is preselected"
    assert_select "[data-test=build-card-palette] [data-test=build-choose-palette]", "Choose Theme"
    assert_select "[data-test=build-palette-preview] [data-mode=dark][style*='#0b1220']:not([hidden])"
    assert_select "[data-test=build-palette-preview] [data-mode=light][style*='#ffffff'][hidden]"
    assert_select "[data-test=build-more-like]", 0, "More like this is gone from the card"

    # Choose Theme posts the selected radio's index, as the browser sends the card's form.
    tap_and_relay(request_row, "palette", "Let's go with the Pitch Two theme.", message_id: themes.id, index: 1)
    assert_equal "Pitch Two", request_row.reload.palette["name"]
    assert_equal "cto", request_row.next_intake_step
    cto = ray_answers("Customize your CTO", { kind: "intake", card: "cto", names: %w[Marble Coach Scout], portrait: "harbor" })
    get build_request_path(request_row.token)
    assert_select "[data-test=build-card-cto] [data-test=build-cto-name-input][value=Marble]", 1, "the name is prefilled"
    assert_select "[data-test=build-card-cto] [data-test=build-choose-cto]", "Wake Up your CTO"
    assert_select "[data-test=build-card-cto] [data-test=build-portrait-dialog] [data-test=build-portrait]", BuildIntake::Portraits::KEYS.size

    tap_and_relay(request_row, "cto", "My CTO is Marbles.", message_id: cto.id, custom_name: "Marbles", portrait: "meadow")
    assert_equal %w[Marbles meadow], [ request_row.reload.cto_name, request_row.cto_avatar ]
    domains = ray_answers("And a domain.", { kind: "intake", card: "address", names: %w[league-hub] })
    get build_request_path(request_row.token)
    assert_select "[data-test=build-card-address] button[data-test=build-address-suggestion][aria-pressed=true]", text: "league-hub"
    assert_select "[data-test=build-card-address] [data-test=build-choose-address]", "Use Domain"

    tap_and_relay(request_row, "address", "Let's use league-hub.mcritchie.app.", message_id: domains.id, subdomain: "league-hub")
    assert_equal "league-hub", request_row.reload.subdomain
    assert_includes response.body, "data-complete=\"true\"", "the tap's stream redraws the status card complete"

    # Ritch sums up; with every step set, code gives the answer the summary card.
    summary = ray_answers("Here's your app.")
    assert_equal({ "card" => "summary" }, summary.intake_card)
    get build_request_path(request_row.token)
    assert_select "[data-test=build-card-summary][data-ready=true]" do
      assert_select "[data-test=build-summary-title]", "League Standings Hub"
      assert_select "[data-test=build-summary-cto]", /Marbles/
      assert_select "[data-test=build-summary-theme]", /Pitch Two/
      assert_select "[data-test=build-summary-domain]", /league-hub\.mcritchie\.app/
      assert_select "[data-test=build-summary-build][data-signs-in=true]", 1, "signed out, Build My App opens sign-in"
    end
    # The status card above the thread holds the same facts, filled tap by tap, and no Build control.
    assert_select "#build-checklist [data-test=build-status-card][data-complete=true]" do
      assert_select "[data-test=build-status-title]", "League Standings Hub"
      assert_select "[data-test=build-tile-agent][data-done=true] [data-test=build-tile-agent-portrait][src*='cto_portraits/meadow']"
      assert_select "[data-test=build-tile-agent-value]", /Marbles/
      assert_select "[data-test=build-tile-theme-value]", /Pitch Two/
      assert_select "[data-test=build-tile-domain-value]", /league-hub\.mcritchie\.app/
      assert_select "[data-test=build-summary-build]", 0
    end

    patch build_request_path(request_row.token), params: { app_request: { subdomain: "league-hub" } }
    assert_equal "draft", request_row.reload.status, "a signed-out Build launches nothing"

    user = User.create!(email: "league@example.com", name: "League Fan", role: "viewer")
    post "/magic_link", params: { email: user.email, return_to: build_request_path(request_row.token) }, as: :json
    post link_consume_path(token: Studio::Link.where(kind: "magic_link").order(:created_at).last.token)
    get build_request_path(request_row.token)
    assert_equal user, request_row.reload.user, "sign-in adopts the draft"
    assert_select "[data-test=build-card-summary] form[action='#{build_request_path(request_row.token)}'] [data-test=build-summary-build]"

    patch build_request_path(request_row.token), params: { app_request: { subdomain: "league-hub" } }
    assert_redirected_to chat_application_path("league-hub")
    request_row.reload
    assert_equal "queued", request_row.status
    app_cto = AppCto.find_by!(app_request_token: request_row.token)
    assert_equal "Marbles", app_cto.name
    assert_includes app_cto.plan, "Key features: Live standings; Game schedules"
    task = Task.find_by!(slug: request_row.task_slug)
    assert_includes task.metadata.dig("devops", "agent_context"), "Key features: Live standings; Game schedules"
  end

  test "Build something else relays to Ritch, who asks for a new direction" do
    request_row = first_message
    idea = ray_answers("Here's the idea.", { kind: "intake", card: "idea", title: "League Standings Hub", features: %w[Standings Schedules] })
    tap_and_relay(request_row, "idea_else", "I'd like to build something else.", message_id: idea.id)
    assert_equal({}, request_row.reload.answers)
    assert_equal "I'd like to build something else.", AgentMessage.claim!(soul: "ray", worker: "mac-1").message.content
  end

  test "a tap on a card from another request's thread is refused and writes nothing" do
    mine = first_message
    ray_answers("Pick colors.", { kind: "intake", card: "palette", palettes: [ PALETTE ] })
    theirs = AppRequest.create!(prompt: "Someone else's")

    tap_card(theirs, "palette", message_id: AgentMessage.where(thread_key: BuildIntake.thread_key(mine.token)).last.id, index: 0)
    assert_response :unprocessable_content
    assert_equal({}, theirs.reload.palette)
  end

  test "Build my app needs the whole checklist" do
    request_row = first_message
    user = User.create!(email: "half@example.com", name: "Half Done", role: "viewer")
    request_row.update!(user: user, subdomain: "half-done")
    post "/magic_link", params: { email: user.email, return_to: "/" }, as: :json
    post link_consume_path(token: Studio::Link.where(kind: "magic_link").order(:created_at).last.token)

    patch build_request_path(request_row.token), params: { app_request: { subdomain: "half-done" } }
    assert_equal "draft", request_row.reload.status
    assert_equal "Finish the steps first.", flash[:alert]
  end

  test "the bot shield: no proof holds the first message; the honeypot stores nothing" do
    post build_path, params: { app_request: { prompt: "price?" } }
    held = AgentMessage.order(:id).last
    assert_equal "held", held.status
    assert_empty AgentMessage.claimable(soul: "ray")

    assert_no_difference -> { AppRequest.count } do
      post build_path, params: { app_request: { prompt: "price?", leave_blank: "http://spam" } }
    end

    too_fast = first_message("quick", proof_age: 0.seconds)
    assert_equal "held", AgentMessage.where(thread_key: BuildIntake.thread_key(too_fast.token)).last.status
  end

  test "past the per-request cap Ritch's reply asks the visitor to sign in" do
    BuildIntake.policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 1 }
    request_row = first_message
    ray_answers("What is it for?")
    say(request_row, "for my league")
    capped = AgentMessage.where(thread_key: BuildIntake.thread_key(request_row.token)).order(:id).last
    assert_equal "completed", capped.status
    assert_includes response.body, "Sign in to continue"
  end
end
