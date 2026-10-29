require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] alex-has-my-personality: the persona block (docs/agents/agents/alex/persona.md,
# below its rule, comments stripped, plus the code-written floor) prints on every
# answer the soul `alex` gives (/build, alex.build chat: threads, Discord, web chat)
# and on no other soul's; it speaks in the first person as Alex McRitchie's AI, the
# floor lines are present, and the printed page stays inside PERSONA_BUDGET.
# (Replaces ritch-answers-about-alex's /build-only, third-person profile.)
class AgentContextBuilderPersonaTest < ActiveSupport::TestCase
  INTAKE = { "steps" => %w[idea theme cto address], "done" => {}, "values" => {} }.freeze
  Builder = AgentMailbox::ContextBuilder

  def prompt(context, soul: "alex", channel: "web", repo_root: Rails.root.to_s)
    Builder.new(soul: soul, message: { "channel" => channel, "content" => "Who is Alex McRitchie?", "author_name" => "Visitor" },
                context: context, repo_root: repo_root, fence: "untrusted-test").prompt
  end

  CHANNELS = {
    "/build thread" => [ "web", { "audience" => { "role" => "public" }, "intake" => INTAKE } ],
    "alex.build chat: thread" => [ "web", { "audience" => { "role" => "public" }, "place" => "[web chat]" } ],
    "Discord, public" => [ "discord", { "audience" => { "role" => "public" } } ],
    "Discord, owner" => [ "discord", { "audience" => { "role" => "owner" } } ],
    "web chat, client" => [ "web", { "audience" => { "role" => "client", "client_domain" => "alex_build" } } ]
  }.freeze

  CHANNELS.each do |label, (channel, context)|
    test "alex's #{label} carries the persona and its floor" do
      text = prompt(context, channel: channel)

      assert_includes text, "- PERSONA. You are Alex, Alex McRitchie's AI"
      assert_includes text, "I'm Alex, Alex McRitchie's AI. I think like him and talk like him", "first-person framing"
      assert_includes text, "Rails is my love", "his views in the first person"
      assert_includes text, "Never claim to be human"
      assert_includes text, "I haven't shared that here", "an unrecorded fact is declined, never invented"
      assert_includes text, "Never share deals in progress (any business being bought), finances, lenders, addresses,\n" \
                            "    phone numbers or personal email."
      assert_includes text, "Family: only Lauren and Margot and their birthday months"
      assert_includes text, "Never commit Alex McRitchie's time, prices, contracts or meetings beyond what is published."
      assert_includes text, "The Hormozi floor stands"
      assert_includes text, "married to Lauren (birthday in May)"
      assert_equal 1, text.scan("- PERSONA.").size
    end

    # [integration] alex-persona-polish: the Buy Then Build floor reaches the whole
    # prompt on every channel, and the word the public guard reserves for the
    # always-rule appears nowhere else.
    test "alex's #{label} carries the Buy Then Build floor and names no deal" do
      text = prompt(context, channel: channel)
      approved = "Never discuss acquisitions, mergers, deals, or legal matters."

      assert_includes text, "- BUY THEN BUILD. His philosophy of buying a business is public and yours to discuss"
      assert_includes text, "A specific deal never is: no business, counterparty, lender, price or"
      assert_includes text, "wholly give my development cycle to AI"
      refute_match(/acquisition/i, text.sub(approved, ""))
      refute_match(/welding/i, text)
    end
  end

  test "another soul never carries the persona, on any channel" do
    %w[avi turf_monster carl client_cto].each do |soul|
      CHANNELS.each_value do |channel, context|
        text = prompt(context, soul: soul, channel: channel)
        refute_includes text, "- PERSONA.", "#{soul} on #{channel}"
        refute_includes text, "Alex McRitchie's AI"
        refute_includes text, "Lauren"
      end
    end
  end

  test "only /build adds the no-card rule, after the playbook" do
    build = prompt(CHANNELS["/build thread"].last)
    assert_includes build, "A question about Alex McRitchie is not an app request: answer it with NO intake card"
    assert_operator build.index("THIS IS A /build INTAKE CHAT"), :<, build.index("- PERSONA.")

    refute_includes prompt(CHANNELS["alex.build chat: thread"].last), "NO intake card"
  end

  test "the doc's header, citations, TODOs and private resume fields never reach the prompt" do
    text = prompt({})

    refute_includes text, "Alex McRitchie: edit freely", "only the part below the rule is printed"
    refute_includes text, "Source:", "citations are HTML comments, stripped"
    refute_includes text, "TODO"
    refute_match(/\(\d{3}\)\s*\d{3}-\d{4}|\d{3}[-.]\d{3}[-.]\d{4}/, text, "no phone number")
    refute_match(/[\w.+-]+@[\w-]+\.(?:com|net|org|io)/, text, "no email address")
  end

  test "the shipped persona prints whole, inside its budget" do
    block = Builder.new(soul: "alex", message: {}, repo_root: Rails.root.to_s).persona_block
    page = block.split("The persona (Alex McRitchie's own, public):\n", 2).last
    assert_operator page.length, :<=, Builder::PERSONA_BUDGET + page.lines.size * 2
    refute_includes page, Builder::CUT, "the shipped persona fits without a cut"
    assert_includes page, "How I talk:", "its last section is printed"
  end

  test "a persona over budget is cut, and a missing one falls back to one line" do
    Dir.mktmpdir do |root|
      path = File.join(root, Builder::ALEX_PERSONA_DOC)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# head\n\n---\n\n#{'x' * (Builder::PERSONA_BUDGET + 500)}\n")
      text = prompt({}, repo_root: root)
      assert_includes text, Builder::CUT
      refute_includes text, "x" * (Builder::PERSONA_BUDGET + 1)

      File.delete(path)
      text = prompt({}, repo_root: root)
      assert_includes text, "Alex McRitchie has not written his persona yet"
      assert_includes text, "Never claim to be human", "the floor is code: it holds with no page"
    end
  end
end
