require "test_helper"

# [component] The shared agent chat (app/views/agent_chats), rendered for an agent
# that is not a CTO, on a thread that is not a CTO chat's: the stream, the thread,
# the typing slot and the composer take the agent and stream they are given; the
# header shows the heading agent's portrait and name; and the composer's
# attachments slot is empty here and fillable without touching the form.
class AgentChatComponentTest < ActionView::TestCase
  AgentStub = Struct.new(:slug, :name, :avatar, :avatar_color, :avatar_initials, keyword_init: true) do
    def shiny? = false
  end

  STREAM = "agent_chat:build:tok123".freeze

  def turns
    [
      AgentMessage.new(id: 41, status: "completed", content: "A pick'em app", response_text: "**Nice.** Who is it for?",
                       completed_at: Time.utc(2026, 10, 17, 9)),
      AgentMessage.new(id: 42, status: "received", content: "Friends")
    ]
  end

  def render_chat(messages: turns, empty: "Tell Ray what you want to build.")
    render partial: "agent_chats/chat", locals: {
      agent_name: "Ray", stream: STREAM, channel: Turbo::StreamsChannel, messages: messages, empty: empty,
      composer: { url: "/build/chat", scope: :build_chat, id: "build-chat-form", error: nil, text: "" }
    }
  end

  test "[component] the shared chat renders the stream, thread, typing slot and composer for the agent and stream it is given" do
    render_chat

    source = css_select("turbo-cable-stream-source").sole
    assert_equal "Turbo::StreamsChannel", source["channel"]
    assert_equal STREAM, Turbo::StreamsChannel.verified_stream_name(source["signed-stream-name"]), "subscribes to the stream it was handed"

    assert_select "##{AgentMessages::WebChat::MESSAGES_TARGET}[role='log'][aria-label='Conversation with Ray'][data-cto-chat-scroll]" do
      assert_select "[data-test='cto-chat-turn']", 2
      assert_select "#cto-chat-turn-41[data-status='completed'][data-replied-at] [data-test='cto-chat-reply'] p.text-muted", text: "Ray"
      assert_select "#cto-chat-turn-41 [data-test='cto-chat-reply'] strong", text: "Nice."
      assert_select "#cto-chat-turn-42[data-status='received'] [data-test='cto-chat-reply']", 0
      assert_select "[data-test='cto-chat-empty']", text: "Tell Ray what you want to build."
    end
    assert_select "##{AgentMessages::WebChat::TYPING_TARGET}[data-fade-seconds='#{AgentMessages::WebChat::TYPING_FADE}']"

    assert_select "form#build-chat-form[action='/build/chat'][data-cto-chat-form]" do
      assert_select "input[type='hidden'][name='build_chat[client_id]']"
      assert_select "textarea[name='build_chat[text]'][placeholder='Message Ray…'][maxlength='#{AgentMessages::WebIngest::MAX_LENGTH}']"
      assert_select "label.sr-only", text: "Message Ray"
    end
    assert_no_match(/Turf|CTO/, rendered, "nothing in the component names the CTO")
  end

  test "[component] no empty-state line unless the caller gives one" do
    render_chat(messages: [], empty: nil)

    assert_select "[data-test='cto-chat-empty']", 0
    assert_select "[data-test='cto-chat-turn']", 0
  end

  test "[component] the typing pulse names the agent" do
    render partial: "agent_chats/typing", locals: { agent_name: "Ray", at: Time.utc(2026, 10, 17, 9) }

    assert_select "[data-test='cto-chat-typing'][data-typing-at='#{(Time.utc(2026, 10, 17, 9).to_f * 1000).to_i}']", text: /Ray is typing…/
  end

  test "[component] the shell's head: the agent's portrait, big and centered, one view-transition name, its name and role under it" do
    ray = AgentStub.new(slug: "ray", name: "Ray", avatar: "https://img.test/ray.png", avatar_color: "#6366f1", avatar_initials: "R")
    render("agent_chats/header", name: "Ray", agent: ray, role: "AI build agent")

    assert_select "[data-test='agent-chat-header'][data-agent-name='Ray']" do
      assert_select "[data-test='agent-portrait'][style='view-transition-name: agent-portrait;'] span.w-24 img[src='https://img.test/ray.png']"
      assert_select "[data-test='agent-caption']", text: /Ray\s+· AI build agent/
    end
    assert_select "h1", 0, "the page's heading is its status slot's"
  end

  test "[component] the header swaps agents: ready portrait markup wins, and with no agent the name's initial stands in" do
    render("agent_chats/header", name: "Nova", portrait: tag.img(src: "/nova.png", alt: "", data: { test: "portrait" }))
    assert_select "[data-test='agent-chat-header'][data-agent-name='Nova'] [data-test='agent-portrait'] [data-test='portrait'][src='/nova.png']"

    @rendered = ActionView::OutputBuffer.new
    render("agent_chats/header", name: "Nova") # no block: the header never yields (a yield would print the layout body again)
    assert_select "[data-test='agent-portrait'] span[aria-hidden='true']", text: "N"
    assert_select "[data-test='agent-caption']", text: "Nova"
  end

  test "[component] the shell stacks head, status and chat, each slot as given" do
    render("agent_chats/shell", page: "app", head: tag.div(data: { test: "h" }), status: tag.div(data: { test: "s" }),
                                chat: tag.div(data: { test: "c" }))

    assert_select "section[data-test='agent-shell'][data-shell='app'] > [data-test='h'] + [data-test='agent-shell-status'][style*='agent-status'] > [data-test='s']"
    assert_select "[data-test='agent-shell-status'] + [data-test='c']"
  end

  test "[component] the composer is the big chat box with a round send button" do
    render_chat
    assert_select "form#build-chat-form.rounded-3xl[style*='view-transition-name: agent-composer']" do
      assert_select "button[type='submit'][data-test='cto-chat-send'][aria-label='Send to Ray'].rounded-full svg"
    end
  end

  test "[component] the attachments slot renders inside the composer, empty, and a filled slot needs no form edit" do
    render_chat
    form = css_select("form#build-chat-form").sole
    assert_equal form.css("label, textarea, input, p, span, button").size, form.css("label, textarea, input, button[data-test='cto-chat-send']").size,
                 "the stock slot adds no markup"

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "agent_chats"))
      File.write(File.join(dir, "agent_chats", "_attachments_slot.html.erb"),
                 %(<%# locals: (form:) %>\n<span data-test="slot-filled" data-scope="<%= form.object_name %>"></span>\n))
      controller.prepend_view_path(dir)
      @view = nil
      @rendered = ActionView::OutputBuffer.new
      render_chat
    end
    assert_select "form#build-chat-form [data-test='slot-filled'][data-scope='build_chat']", 1,
                  "the slot renders inside the form with the composer's form builder"
    assert_select "form#build-chat-form [data-test='slot-filled'] + div textarea", 1, "it sits right above the input row"
  end
end
