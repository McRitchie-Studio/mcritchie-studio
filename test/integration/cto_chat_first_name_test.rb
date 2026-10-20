require "test_helper"
require_relative "../support/client_cto_fixtures"

# [integration] A nameless owner on their app's CTO chat (task
# cto-chat-quality-pass, Alex 2026-10-19: "The first name is weird"): the CTO
# asks for a first name in its greeting, the engine's first-name modal is never
# armed on the chat (nor over the launch panel), and the owner's reply saves the
# name (or skips) in code, with no model run. Off the chat the modal still asks.
class CtoChatFirstNameTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures

  MODAL_MARKER = "#onboarding-ask-first-name".freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentPerson.seed_owner!
    @owner = User.create!(email: "new-builder@example.test")
    request = AppRequest.create!(prompt: "A booking site for my groomer", user: @owner)
    AppLaunch.new(request, subdomain: "pawsome", intake: client_intake).call!
  end

  teardown { AgentMessages::Answerers.reset! }

  def send_chat(text)
    post chat_application_path("pawsome"), params: { cto_chat: { text: text, client_id: SecureRandom.hex(8) } }, as: :turbo_stream
    assert_response :success
    AgentMessage.where(channel: "web", channel_ref: "pawsome").order(:id).last
  end

  def open_chat
    log_in_as(@owner)
    get chat_application_path("pawsome") # the first visit plays the launch panel
    assert_select "[data-test='build-launch']"
    assert_select MODAL_MARKER, 0, "no first-name modal over the launch panel"
    get chat_application_path("pawsome")
    assert_response :success
  end

  test "[integration] a nameless owner: the CTO asks in the chat and the modal is not armed on the page" do
    open_chat
    assert_select "[data-test='cto-chat-reply']", text: /Hi there, I'm Nova/
    assert_select "[data-test='cto-chat-reply']", text: /what should I call you\?/
    assert_select MODAL_MARKER, 0, "the chat asks; the engine modal stays off this page"

    get packages_path
    assert_select MODAL_MARKER, 1, "off the chat the engine's modal still asks"
  end

  test "[integration] the reply saves the first name in code, and the modal stops asking everywhere" do
    open_chat
    reply = nil
    assert_no_difference -> { AgentMessage.where(status: "received").count }, "no model is asked" do
      assert_enqueued_with(job: AgentMessageReplyJob) { reply = send_chat("my name is ada") }
    end
    assert_equal [ "completed", "first name", "saved" ], [ reply.status, reply.action_summary, reply.run_meta["first_name"] ]
    assert_match(/\ANice to meet you, Ada!/, reply.response_text)
    assert_equal [ "Ada", "Ada" ], [ @owner.reload.first_name, @owner.name ]
    assert_includes reply.response_text, %(Not right? Say "call me" and your name.)

    fix = send_chat("call me Ace")
    assert_equal [ "completed", "saved" ], [ fix.status, fix.run_meta["first_name"] ], "the very next cued message corrects it"
    assert_equal "Ace", @owner.reload.first_name

    nxt = send_chat("Can you add a gallery?")
    assert_equal "received", nxt.status, "after the ask, the model answers as usual"
    assert_equal "Ace", nxt.author_name, "and the CTO's next turns know the name"

    get packages_path
    assert_select MODAL_MARKER, 0
  end

  test "[integration] a skip is answered in code, leaves the name blank and is the engine's session skip" do
    open_chat
    reply = send_chat("skip")
    assert_equal [ "completed", "skipped" ], [ reply.status, reply.run_meta["first_name"] ]
    assert_match(/\ANo problem\./, reply.response_text)
    assert_nil @owner.reload.first_name
    assert session[Studio::FIRST_NAME_SKIP_SESSION_KEY]
    get packages_path
    assert_select MODAL_MARKER, 0, "skipped for this session"
  end

  test "[integration] a first message that is not a name goes to the model and ends the ask" do
    open_chat
    message = send_chat("Add dark mode") # Carl's trigger: a request, not a name
    assert_equal "received", message.status, "the request reaches the model"
    assert_equal "received", message.status
    assert_nil @owner.reload.first_name
    assert_equal "received", send_chat("Ada").status, "only the first message after the ask is read as a name"
    assert_equal "received", send_chat("call me Ada").status, "nor a cued one: no name was saved to correct"
    assert_nil @owner.reload.first_name
  end

  test "[integration] an owner with a name is greeted by it and never asked" do
    named = users(:viewer)
    request = AppRequest.create!(prompt: "A second site", user: named)
    AppLaunch.new(request, subdomain: "fetchly", intake: client_intake).call!
    log_in_as(named)
    get chat_application_path("fetchly")
    get chat_application_path("fetchly")
    assert_select "[data-test='cto-chat-reply']", text: /Hi Viewer/
    assert_select "[data-test='cto-chat-reply']", text: /what should I call you/, count: 0
  end
end
