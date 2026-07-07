require "test_helper"

class AgentAvatarComponentTest < ActionView::TestCase
  AgentStub = Struct.new(:name, :avatar, :avatar_color, :avatar_initials, :shiny, keyword_init: true) do
    def shiny?
      shiny == true
    end
  end

  def render_avatar(size: "xs", shiny: true)
    agent = AgentStub.new(name: "Pikachu", avatar: "https://img.test/pikachu.png",
                          avatar_color: "#facc15", avatar_initials: "P", shiny: shiny)
    render partial: "components/agent_avatar", locals: { agent: agent, size: size }
  end

  test "[component] shiny badge is large raw emoji without circular background" do
    render_avatar

    assert_select "[data-test='avatar-shiny-badge']", text: "✨" do |badges|
      badge_class = badges.first["class"]
      assert_includes badge_class, "text-lg"
      assert_no_match(/\bbg-/, badge_class)
      assert_no_match(/\bborder\b/, badge_class)
      assert_no_match(/\brounded-full\b/, badge_class)
      assert_no_match(/\bshadow-sm\b/, badge_class)
    end
  end

  test "[component] plain avatars do not render a shiny badge" do
    render_avatar(shiny: false)

    assert_select "[data-test='avatar-shiny-badge']", count: 0
  end
end
