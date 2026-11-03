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
end
