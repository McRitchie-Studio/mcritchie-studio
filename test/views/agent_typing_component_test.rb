require "test_helper"

# [component] A pending answer's indicator (agent_chats/_typing; task
# chat-thinking-versus-typing): both looks are drawn in one cell and data-phase
# picks the one shown. THINKING is the agent's portrait in the orbit (an Agent
# row's avatar, a client CTO's own portrait, or the name's initial) with
# "<Agent> is thinking" on the shimmer; TYPING is the bubble of three dots with
# "<Agent> is typing". A phase outside the allow-list draws as typing, the look
# every pulse had before phases. The data-test hooks the fade and the e2e read
# (cto-chat-typing, data-typing-at) are kept.
class AgentTypingComponentTest < ActionView::TestCase
  AgentStub = Struct.new(:slug, :name, :avatar, :avatar_color, :avatar_initials, keyword_init: true) do
    def shiny? = false
  end

  AT = Time.utc(2026, 10, 18, 19, 30)

  def ray = AgentStub.new(slug: "ray", name: "Ritch", avatar: "/agents/ray.png", avatar_color: "#123456", avatar_initials: "R")

  def render_typing(**locals)
    render partial: "agent_chats/typing", locals: { agent_name: "Ritch", at: AT, **locals }
  end

  test "[component] thinking: the portrait in the orbit and 'Ritch is thinking' on the shimmer, the bubble drawn but not chosen" do
    render_typing(phase: "thinking", agent: ray)

    assert_select ".agent-typing[data-test='cto-chat-typing'][data-phase='thinking'][data-typing-at='#{(AT.to_f * 1000).to_i}']" do
      assert_select ".agent-typing-thinks[data-test='cto-chat-thinking']" do
        assert_select ".agent-typing-orbit[aria-hidden='true'] img[src='/agents/ray.png']"
        assert_select ".agent-typing-orbit .w-10.h-10", 1, "the small portrait"
        assert_select ".agent-typing-label.agent-typing-shimmer", text: "Ritch is thinking"
      end
      assert_select ".agent-typing-types[data-test='cto-chat-typing-bubble'] .agent-typing-label", text: "Ritch is typing"
    end
  end

  test "[component] typing: the bubble's three dots and 'Ritch is typing'" do
    render_typing(phase: "typing", agent: ray)

    assert_select ".agent-typing[data-phase='typing']" do
      assert_select ".agent-typing-bubble[aria-hidden='true'] .agent-typing-dot", 3
      assert_select ".agent-typing-types .agent-typing-label", text: "Ritch is typing"
    end
  end

  test "[component] no phase, or one off the allow-list, draws typing; no portrait falls back to the initial" do
    render_typing
    assert_select ".agent-typing[data-phase='typing']"

    render_typing(phase: "<script>")
    assert_select ".agent-typing[data-phase='typing']", 2
    assert_no_match(/<script>/, rendered)
    assert_select ".agent-typing-orbit span", text: "R"
  end

  test "[component] a client CTO's thinking look wears its own portrait" do
    app_cto = AppCto.new(app_slug: "pawsome", name: "Biscuit", portrait: "canyon", palette: {})
    cto = AppOwnership::Cto.new(app_slug: "pawsome", soul: AppCto::SOUL, agent: nil, display_name: "Biscuit", app_cto: app_cto)
    render partial: "agent_chats/typing", locals: { agent_name: "Biscuit", at: AT, phase: "thinking", cto: cto }

    assert_select ".agent-typing-orbit [data-test='client-cto-avatar'].w-10"
    assert_select ".agent-typing-thinks .agent-typing-label", text: "Biscuit is thinking"
  end
end
