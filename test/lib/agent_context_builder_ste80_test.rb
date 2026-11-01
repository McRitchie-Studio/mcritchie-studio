require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] STE-80, the reply primitive (docs/agents/modules/plain-technical-english.md):
# every dispatched prompt, for every audience, cold and warm, prints
# ContextBuilder::STE80_RULE in HOW TO ANSWER, and the module quotes the same words.
class AgentContextBuilderSte80Test < ActiveSupport::TestCase
  FENCE = "untrusted-ste80".freeze
  CB = AgentMailbox::ContextBuilder
  W = AgentMailbox::WarmSession
  MODULE = "docs/agents/modules/plain-technical-english.md".freeze

  AUDIENCES = {
    "owner" => AgentMailbox::Audience.new(role: "owner"),
    "team" => AgentMailbox::Audience.new(role: "team"),
    "client" => AgentMailbox::Audience.new(role: "client", client_domain: "turf"),
    "public" => AgentMailbox::Audience.new(role: "public")
  }.freeze

  setup do
    @root = Dir.mktmpdir("ste80-root")
    FileUtils.mkdir_p(File.join(@root, "docs/agents/agents/alex"))
    File.write(File.join(@root, "docs/agents/agents/alex/role.md"), "Alex orchestrates.")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/agent_domains.yml"), <<~YAML)
      domains:
        studio: { name: McRitchie Studio, doc: docs/studio.md }
      souls: { alex: studio }
    YAML
    File.write(File.join(@root, "docs/studio.md"), "The hub and its agents.")
    FileUtils.mkdir_p(File.join(@root, "docs/agents/modules"))
    FileUtils.cp(Rails.root.join(AgentMailbox::Audience::SOP_PATH), File.join(@root, AgentMailbox::Audience::SOP_PATH))
    @message = { "id" => 9, "channel" => "slack", "author_name" => "Alex", "content" => "what next?" }
  end

  teardown { FileUtils.rm_rf(@root) }

  def builder(audience)
    CB.new(soul: "alex", message: @message, context: nil, repo_root: @root, fence: FENCE, audience: audience)
  end

  def how_to_answer(prompt) = prompt[/^HOW TO ANSWER$.*?(?=^== USER: )/m]

  test "the rule names the STE-80 essentials and no internal path" do
    rule = CB::STE80_RULE
    [ "ASD-STE100", "one idea per sentence", "under 20 words", "active voice", "numbered lists for steps",
      "Keep your own voice", "Never rewrite code" ].each { |bit| assert_includes rule, bit }
    refute_match(%r{docs/|bin/|config/}, rule, "client and public prompts print it: no internal paths")
    assert_operator rule.length, :<, 500, "keep the prompt delta small"
  end

  AUDIENCES.each do |label, audience|
    test "a cold #{label} prompt prints the rule inside HOW TO ANSWER, outside every fence" do
      prompt = builder(audience).prompt
      rules = how_to_answer(prompt)
      assert rules, "HOW TO ANSWER is present"
      assert_includes rules, CB::STE80_RULE
      assert_includes prompt.gsub(%r{<#{FENCE}>.*?</#{FENCE}>}m, ""), CB::STE80_RULE
      assert_equal 1, prompt.scan(CB::STE80_RULE).size, "printed once"
    end

    test "a resumed warm #{label} prompt prints the rule, and a fresh one is the cold prompt" do
      resumed = builder(audience).warm_prompt(W::Turn.new(domain: "studio", resume_id: "sess-0001"))
      assert_includes resumed, "You are speaking with: #{label}"
      assert_includes resumed, CB::STE80_RULE
      fresh = builder(audience).warm_prompt(W::Turn.new(domain: "studio", resume_id: nil))
      assert_includes fresh, CB::STE80_RULE
    end
  end

  test "the module quotes the rule word for word" do
    body = Rails.root.join(MODULE).read
    quoted = body[/<!-- ste80-rule:begin -->\s*```text\n(.*?)\n\s*```\s*<!-- ste80-rule:end -->/m, 1]
    assert quoted, "#{MODULE} keeps the rule between its ste80-rule markers"
    squash = ->(text) { text.split.join(" ") }
    assert_equal squash.(CB::STE80_RULE), squash.(quoted)
  end
end
