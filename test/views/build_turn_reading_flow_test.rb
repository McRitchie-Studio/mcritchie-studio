# frozen_string_literal: true

require "test_helper"

# [component] The /build turn's reading flow (build/_turn over agent_chats/_turn;
# task build-chat-reading-flow): Ray's words are plain text on the page, the
# visitor's keep their right-hand bubble, and the intake card his answer carries
# keeps its bubble as the point of action, marked so it waits for the words to
# finish typing (agent-action, app/assets/tailwind/agent_reply.css).
class BuildTurnReadingFlowTest < ActionView::TestCase
  include ApplicationHelper
  include AgentShellHelper

  setup do
    @row = AppRequest.create!(prompt: "A league site")
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }
  end

  def turn(**attrs)
    AgentMessage.create!({ channel: "web", external_id: "build:#{@row.token}:#{SecureRandom.hex(4)}", channel_ref: "build",
                           thread_key: BuildIntake.thread_key(@row.token), soul_slug: "ray", content: "A league site" }.merge(attrs))
  end

  test "[component] Ray's words unbubbled, the visitor's bubbled, the idea card bubbled as the point of action" do
    message = turn(status: "completed", response_text: "Here's the app **I hear**.",
                   intake_card: { "card" => "idea", "title" => "League Hub", "features" => [ "Standings" ] })
    render partial: "build/turn", locals: { message: message, request_row: @row }

    assert_select "#build-turn-#{message.id}[data-build-turn]" do
      reply = css_select("[data-test='cto-chat-reply']").sole
      assert_equal "false", reply["data-bubble"]
      assert_empty reply["class"].split & %w[card rounded-2xl border bg-surface], "the answer sits on the page"
      assert_select "[data-test='cto-chat-reply'] [data-agent-reveal] strong", text: "I hear"

      assert_select "[data-test='cto-chat-sent'].self-end.rounded-2xl", text: "A league site"

      card = css_select("[data-test='build-card'][data-card='idea'][data-action-card]").sole
      assert_includes card["class"].split, "agent-action"
      assert_select "[data-test='build-card'] > [data-test='build-card-idea']", 1, "the card draws its own bubble inside the action wrapper"
    end
  end

  test "[component] a pending turn shows the visitor's bubble and the thinking look, no answer and no card yet" do
    message = turn(status: "received")
    render partial: "build/turn", locals: { message: message, request_row: @row }

    assert_select "[data-test='cto-chat-sent']", 1
    assert_select "[data-test='cto-chat-typing'][data-phase='thinking']", 1
    assert_select "[data-test='cto-chat-reply'], [data-action-card]", 0
  end
end
