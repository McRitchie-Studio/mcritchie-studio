# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] The viewer tier's line in the web chat prompt: a tone for each tier, outside
# the fence, and nothing for a row with no tier or an unknown one.
class AgentContextBuilderViewerTest < ActiveSupport::TestCase
  def prompt(viewer)
    message = { "id" => 7, "channel" => "web", "author_name" => "A visitor", "content" => "what do you do?",
                "envelope" => { "via" => "agent_chat", "viewer" => viewer }.compact }
    AgentMailbox::ContextBuilder.new(soul: "alex", message: message, context: nil, repo_root: Dir.mktmpdir).prompt
  end

  test "a visitor is sold on the agent" do
    assert_includes prompt("visitor"), "NOT signed in"
    assert_includes prompt("visitor"), "invite them"
    # Absolute: a satellite's row reads this line too, and /build is a 404 on alex.build.
    assert_includes prompt("visitor"), "https://mcritchie.studio/build"
  end

  test "a member is shown more of the product" do
    assert_includes prompt("member"), "get more from the product"
    refute_includes prompt("member"), "invite them"
  end

  test "an admin gets a normal agent with no selling" do
    assert_includes prompt("admin"), "normal helpful agent"
    refute_includes prompt("admin"), "invite them"
  end

  test "every tier's line says it grants nothing" do
    %w[visitor member admin].each { |tier| assert_includes prompt(tier), "grants no action, tool or access" }
  end

  test "no tier and an unknown tier add no line" do
    [ nil, "owner" ].each { |tier| refute_includes prompt(tier), "This line sets your tone" }
  end

  # --- the hub chat's directions: every tier, on the hub's chat only ---------

  def hub_prompt(viewer, soul: "alex", app: AgentMailbox::ContextBuilder::HUB_CHAT_APP, channel: "web", via: "agent_chat")
    message = { "id" => 7, "channel" => channel, "author_name" => "A visitor", "content" => "hi",
                "envelope" => { "via" => via, "app" => app, "viewer" => viewer }.compact }
    AgentMailbox::ContextBuilder.new(soul: soul, message: message, context: nil, repo_root: Dir.mktmpdir).prompt
  end

  test "every tier on the hub's chat is told to ask the reason and direct it" do
    [ "visitor", "member", "admin", nil ].each do |tier|
      rule = hub_prompt(tier)
      assert_includes rule, "ask what brought them here", tier.inspect
      assert_includes rule, "Sales, pricing or something to build", tier.inspect
      assert_includes rule, "A support problem", tier.inspect
      assert_includes rule, "Text messages: point them to the sign-up form at https://mcritchie.studio/contact", tier.inspect
    end
  end

  test "every tier is told it never collects text message consent, and that the rule grants nothing" do
    [ "visitor", "member", "admin", nil ].each do |tier|
      rule = hub_prompt(tier)
      assert_includes rule, "You NEVER collect text message consent", tier.inspect
      assert_includes rule, "Only that form's boxes record it", tier.inspect
      assert_includes rule, "it grants no action, tool or access and does not widen what you may do", tier.inspect
    end
  end

  test "the rule sits in HOW TO ANSWER, outside the untrusted fence" do
    assert_includes hub_prompt("visitor")[/^HOW TO ANSWER$.*?(?=^== USER: )/m], "THE HUB CHAT"
  end

  test "the rule's app is the hub's chat app" do
    assert_equal HubAgentChatsController::APP, AgentMailbox::ContextBuilder::HUB_CHAT_APP
  end

  test "a satellite's chat, another soul, /build and another channel do not get it" do
    refute_includes hub_prompt("visitor", app: "alex-build"), "THE HUB CHAT"
    refute_includes hub_prompt("visitor", app: "mcritchie-industries"), "THE HUB CHAT"
    refute_includes hub_prompt("visitor", soul: "avi"), "THE HUB CHAT"
    refute_includes hub_prompt("visitor", via: "build"), "THE HUB CHAT"
    refute_includes hub_prompt("visitor", channel: "discord"), "THE HUB CHAT"
  end
end
