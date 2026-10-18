require "test_helper"

# [integration] A signed-out visitor builds with Xan through real requests: the
# first message (bot-shielded) starts a draft and Xan's thread, Xan's answers
# (completed here as bin/dispatcher would, with intake cards) render as cards,
# the status card appears with the first card and each tap fills its tiles
# (Agent, Theme, Domain), and signing in adopts the request and Build queues it
# through the existing claim path. The Build control itself is Ray's summary
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

  # Xan's answer, as the dispatcher completes it.
  def xan_answers(text, card = nil)
    claim = AgentMessage.claim!(soul: "xan", worker: "mac-1")
    assert claim.message, "Xan should have a message to answer"
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

  test "a signed-out visitor goes from idea to a full status card, then signs in and the build is queued" do
    request_row = first_message
    assert_redirected_to build_request_path(request_row.token)
    first = AgentMessage.find_by!(thread_key: BuildIntake.thread_key(request_row.token))
    assert_equal %w[received xan public], [ first.status, first.soul_slug, first.person.role ]

    get build_request_path(request_row.token)
    assert_response :success
    assert_select "[data-test=build-chat-page]"
    assert_select "[data-test=build-turn][data-pending=true]", 1, "Ray's answer is pending, so the page polls"
    assert_select "#build-checklist[data-card=false] [data-test=build-heading]", 1, "no card yet: the heading, not an empty form"
    assert_select "[data-test=build-my-app]", 0, "the status card carries no Build control"

    idea = xan_answers("Got it: a league site. Here's how I'd put it.",
                       { kind: "intake", card: "idea", idea: "A league site with live standings", audience: "rec league players" })
    get build_request_turns_path(request_row.token), params: { ids: first.id }
    assert_response :success
    assert_includes response.body, "build-turn-#{first.id}"
    assert_includes response.body, "data-test=\"build-card-idea\""
    assert_includes response.body, "data-test=\"build-status-card\"", "the first card brings the status card in the same poll"

    tap_card(request_row, "idea", message_id: idea.id)
    assert_response :success
    assert_equal "A league site with live standings", request_row.reload.answers["idea"]

    say(request_row, "Love it")
    cto = xan_answers("Who should run it?", { kind: "intake", card: "cto", names: %w[Coach Ref Scout], portrait: "harbor" })
    get build_request_path(request_row.token)
    assert_select "[data-test=build-card-cto] [data-test=build-portrait]", BuildIntake::Portraits::KEYS.size
    assert_select "[data-test=build-card-cto] input[name=name][value=Coach]"

    tap_card(request_row, "cto", message_id: cto.id, name: "Coach", custom_name: "", portrait: "harbor")
    assert_equal %w[Coach harbor], [ request_row.reload.cto_name, request_row.cto_avatar ]

    say(request_row, "Next")
    colors = xan_answers("Pick some colors.", { kind: "intake", card: "palette", palettes: [ PALETTE ] })
    get build_request_path(request_row.token)
    assert_select "[data-test=build-palette-preview] [data-mode=light][style*='#ffffff']"
    assert_select "[data-test=build-palette-preview] [data-mode=dark][style*='#0b1220']"
    tap_card(request_row, "palette", message_id: colors.id, index: 0)
    assert_equal "Pitch", request_row.reload.palette["name"]

    say(request_row, "Next")
    xan_answers("And an address.", { kind: "intake", card: "address", names: %w[league-hub] })
    tap_card(request_row, "address", subdomain: "league-hub")
    assert_equal "league-hub", request_row.reload.subdomain
    assert_includes response.body, "data-complete=\"true\"", "the tap's stream redraws the status card complete"

    get build_request_path(request_row.token)
    assert_select "[data-test=build-status-card][data-complete=true]" do
      assert_select "[data-test=build-tile-agent][data-done=true] [data-test=build-tile-agent-portrait][src*='cto_portraits/harbor']"
      assert_select "[data-test=build-tile-agent-value]", text: "Coach"
      assert_select "[data-test=build-tile-theme-value]", text: "Pitch"
      assert_select "[data-test=build-tile-domain-value]", text: "league-hub.mcritchie.studio"
      assert_select "[data-test=build-status-title]", text: "League Hub"
    end
    assert_equal "draft", request_row.reload.status

    patch build_request_path(request_row.token), params: { app_request: { subdomain: "league-hub" } }
    assert_equal "draft", request_row.reload.status, "a signed-out Build queues nothing"

    user = User.create!(email: "league@example.com", name: "League Fan", role: "viewer")
    post "/magic_link", params: { email: user.email, return_to: build_request_path(request_row.token) }, as: :json
    post link_consume_path(token: Studio::Link.where(kind: "magic_link").order(:created_at).last.token)
    get build_request_path(request_row.token)
    assert_equal user, request_row.reload.user, "sign-in adopts the draft"

    patch build_request_path(request_row.token), params: { app_request: { subdomain: "league-hub" } }
    request_row.reload
    assert_equal "queued", request_row.status
    assert_equal "league-hub.mcritchie.studio", request_row.host
    task = Task.find_by!(slug: request_row.task_slug)
    assert_includes task.metadata.dig("devops", "agent_context"), "CTO: Coach (portrait harbor)"
  end

  test "a tap on a card from another request's thread is refused and writes nothing" do
    mine = first_message
    xan_answers("Pick colors.", { kind: "intake", card: "palette", palettes: [ PALETTE ] })
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
    assert_equal "Finish setting up your app first.", flash[:alert]
  end

  test "the bot shield: no proof holds the first message; the honeypot stores nothing" do
    post build_path, params: { app_request: { prompt: "price?" } }
    held = AgentMessage.order(:id).last
    assert_equal "held", held.status
    assert_empty AgentMessage.claimable(soul: "xan")

    assert_no_difference -> { AppRequest.count } do
      post build_path, params: { app_request: { prompt: "price?", leave_blank: "http://spam" } }
    end

    too_fast = first_message("quick", proof_age: 0.seconds)
    assert_equal "held", AgentMessage.where(thread_key: BuildIntake.thread_key(too_fast.token)).last.status
  end

  test "past the per-request cap Xan's reply asks the visitor to sign in" do
    BuildIntake.policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 1 }
    request_row = first_message
    xan_answers("What is it for?")
    say(request_row, "for my league")
    capped = AgentMessage.where(thread_key: BuildIntake.thread_key(request_row.token)).order(:id).last
    assert_equal "completed", capped.status
    assert_includes response.body, "Sign in to continue"
  end
end
