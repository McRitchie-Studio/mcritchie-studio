require "test_helper"

# [component] The CTO web chat page as rendered (app/views/cto_chats): the thread
# with each turn's state, the subscription through CtoChatChannel, the usage meter
# in tokens, the typing slot, the composer, the held notice for an account the
# CTO does not answer yet, and the no-chat state. Plus the chat links on the app
# and CTO settings pages.
class CtoChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    AgentPerson.seed_owner!
    @alex = users(:alex)
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  def ingest(user, text) = AgentMessages::WebIngest.new(user: user, cto: AppOwnership.cto_for_app("turf-monster")).call(text)

  test "[component] the owner's chat renders the thread, the stream, the meter, the typing slot and the composer" do
    answered = ingest(@alex, "How are signups?")
    answered.update!(status: "completed", response_text: "**Twelve** this week.", completed_at: Time.current)
    waiting = ingest(@alex, "And errors?")

    log_in_as(@alex)
    get chat_application_path("turf-monster")
    assert_response :success

    assert_select "[data-test='cto-chat-page'][data-app='turf-monster'][data-soul='turf_monster']"
    assert_select "h1", text: "Chat with Turf"
    assert_select "turbo-cable-stream-source[channel='CtoChatChannel']", 1
    signed = css_select("turbo-cable-stream-source").first["signed-stream-name"]
    assert_equal AgentMessages::WebChat.stream_name("turf-monster", @alex.id), CtoChatChannel.verified_stream_name(signed)

    assert_select "#cto-chat-messages[role='log'] [data-test='cto-chat-turn']", 2
    assert_select "#cto-chat-turn-#{answered.id}[data-status='completed'][data-replied-at] [data-test='cto-chat-reply'] strong", text: "Twelve"
    assert_select "#cto-chat-turn-#{waiting.id}[data-status='received'] [data-test='cto-chat-reply']", 0
    assert_select "#cto-chat-meter [data-test='usage-meter']"
    assert_no_match(/\$\d/, css_select("[data-test='cto-chat-usage']").text, "tokens, never dollars, even for an admin")
    assert_select "#cto-chat-typing[data-fade-seconds='#{AgentMessages::WebChat::TYPING_FADE}']"
    assert_select "form#cto-chat-form[action='#{chat_application_path('turf-monster')}'] textarea[maxlength='#{AgentMessages::WebIngest::MAX_LENGTH}']"
    assert_select "form#cto-chat-form input[type='hidden'][name='cto_chat[client_id]']"
    assert_select "[data-test='cto-chat-unanswered']", 0, "the owner is answered"
    assert_select "script[type='module']", text: /import "cto_chat"/
  end

  test "[component] an owner the CTO does not answer yet is told so, and a held turn says it waits for an admin" do
    ingest(@owner, "hello")

    log_in_as(@owner)
    get chat_application_path("turf-monster")
    assert_response :success
    assert_select "[data-test='cto-chat-unanswered']", text: /does not answer your account yet/
    assert_select "[data-test='cto-chat-turn'][data-status='held'] [data-test='cto-chat-held']", text: /Waiting for an admin/
  end

  test "[component] an empty thread shows the prompt; the user's bubble is their text, escaped" do
    log_in_as(@alex)
    get chat_application_path("turf-monster")
    assert_select "[data-test='cto-chat-empty']", text: /Ask Turf anything about Turf Monster/

    ingest(@alex, "<b>bold?</b>")
    get chat_application_path("turf-monster")
    assert_select "[data-test='cto-chat-sent'] b", 0
    assert_select "[data-test='cto-chat-sent']", text: "<b>bold?</b>"
  end

  test "[component] a CTO with no web chat shows that state and subscribes to nothing" do
    AgentMessages::Routes.current = AgentMessages::Routes.new("web" => { "souls" => [ "avi" ] })
    log_in_as(@alex)
    get chat_application_path("turf-monster")

    assert_select "[data-test='cto-chat-unavailable']", text: /Turf has no web chat yet/
    assert_select "turbo-cable-stream-source", 0
    assert_select "form#cto-chat-form", 0

    get application_path("turf-monster")
    assert_select "[data-test='application-cto-chat']", 0
  ensure
    AgentMessages::Routes.reset!
  end

  test "[component] the app page and the CTO settings page link the chat" do
    log_in_as(@owner)
    get application_path("turf-monster")
    assert_select "[data-test='application-cto-chat'][href='#{chat_application_path('turf-monster')}']", text: "Chat"
    assert_select "[data-test='application-cto-settings']"

    get settings_agent_path("turf-monster")
    assert_select "[data-test='agent-chat-card'] [data-test='agent-chat-link'][href='#{chat_application_path('turf-monster')}']"
  end
end
