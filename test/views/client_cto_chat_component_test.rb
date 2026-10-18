require "test_helper"
require_relative "../support/client_cto_fixtures"

# [component] The client CTO in the shared chat: its avatar is the chosen
# portrait over its initial on the palette's primary (both modes' colours as
# CSS custom properties, only validated hex), and Xan's handover turn renders as
# Xan's, on the left, never as the owner's own bubble.
class ClientCtoChatComponentTest < ActionView::TestCase
  include ClientCtoFixtures
  helper ClientCtoHelper

  def client_cto
    AppOwnership.cto_for_app(client_app!.slug)
  end

  test "[component] the avatar shows the portrait key's image over the initial, tinted by the palette in both modes" do
    render partial: "applications/cto_avatar", locals: { cto: client_cto }

    avatar = css_select("[data-test='client-cto-avatar']").sole
    assert_includes avatar["style"], "--cto-primary-light: 79 70 229;"
    assert_includes avatar["style"], "--cto-primary-dark: 129 140 248;"
    assert_includes avatar["class"], "dark:[--cto-primary:var(--cto-primary-dark)]"
    assert_select "[data-test='client-cto-avatar'] span", text: "N"
    assert_select "[data-test='client-cto-portrait'][alt='Nova'][src*='cto_portraits/harbor']"
  end

  test "[component] an upload ref or a bad palette value renders the initial alone and no colour" do
    cto = client_cto
    cto.app_cto.portrait = "upload:abcdefgh12"
    cto.app_cto.palette = PALETTE.deep_merge("light" => { "primary" => "red; background:url(x)" })
    render partial: "applications/cto_avatar", locals: { cto: cto }

    assert_select "[data-test='client-cto-portrait']", 0
    style = css_select("[data-test='client-cto-avatar']").sole["style"]
    refute_includes style, "--cto-primary-light"
    refute_includes style, "url("
  end

  test "[component] Xan's handover is Xan's turn, then the CTO's greeting" do
    message = AgentMessage.new(id: 7, status: "completed", content: "Meet Nova, your CTO. I'll hand you over.",
                               response_text: "Hi Pat, I'm **Nova**.", completed_at: Time.utc(2026, 10, 17, 9),
                               envelope: { "via" => "handover" })
    render partial: "agent_chats/turn", locals: { message: message, agent_name: "Nova" }

    assert_select "[data-test='cto-chat-handover'] p.text-muted", text: "Ray"
    assert_select "[data-test='cto-chat-handover']", text: /Meet Nova, your CTO/
    assert_select "[data-test='cto-chat-sent']", 0, "the handover is not the owner's own bubble"
    assert_select "[data-test='cto-chat-reply'] strong", text: "Nova"
  end
end
