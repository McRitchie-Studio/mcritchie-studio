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

  # --- the contact page's directions: the hub's web chat, every tier ---------

  def hub_prompt(viewer, soul: "alex", app: AgentMailbox::ContextBuilder::CONTACT_PAGE_APP, channel: "web", via: "agent_chat")
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
      assert_includes rule, "Text messages: point them to the form on this page", tier.inspect
    end
  end

  test "every tier is told it never collects text message consent, and that the rule grants nothing" do
    [ "visitor", "member", "admin", nil ].each do |tier|
      rule = hub_prompt(tier)
      assert_includes rule, "You NEVER collect text message consent", tier.inspect
      assert_includes rule, "Only the form's boxes record it", tier.inspect
      assert_includes rule, "it grants no action, tool or access and does not widen what you may do", tier.inspect
    end
  end

  test "the rule sits in HOW TO ANSWER, outside the untrusted fence" do
    text = hub_prompt("visitor")
    rules = text[/^HOW TO ANSWER$.*?(?=^== USER: )/m]
    assert_includes rules, "THE CONTACT PAGE"
  end

  test "the rule's app is the hub's chat app" do
    assert_equal HubAgentChatsController::APP, AgentMailbox::ContextBuilder::CONTACT_PAGE_APP
  end

  # A satellite's chat has no such form beside it, so these directions would be false there.
  test "a satellite's chat, another soul, /build and another channel do not get it" do
    refute_includes hub_prompt("visitor", app: "alex-build"), "THE CONTACT PAGE"
    refute_includes hub_prompt("visitor", app: "mcritchie-industries"), "THE CONTACT PAGE"
    refute_includes hub_prompt("visitor", soul: "avi"), "THE CONTACT PAGE"
    refute_includes hub_prompt("visitor", via: "build"), "THE CONTACT PAGE"
    refute_includes hub_prompt("visitor", channel: "discord"), "THE CONTACT PAGE"
  end
end
