require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] ritch-answers-about-alex: on a /build thread the prompt carries Alex's
# profile (docs/agents/agents/ray/about-alex.md, below its rule, comments
# stripped) and the code-written rules for it: third person, the family limit,
# no intake card for a question about him. No other thread carries either.
class AgentContextBuilderAboutAlexTest < ActiveSupport::TestCase
  INTAKE = { "steps" => %w[idea theme cto address], "done" => {}, "values" => {} }.freeze

  def prompt(context, repo_root: Rails.root.to_s)
    AgentMailbox::ContextBuilder.new(soul: "ray", message: { "channel" => "web", "content" => "Who is Alex?", "author_name" => "Visitor" },
                                     context: context, repo_root: repo_root, fence: "untrusted-test").prompt
  end

  test "a /build prompt carries the profile, the third-person rule and the family limit" do
    text = prompt({ "audience" => { "role" => "public" }, "intake" => INTAKE })

    assert_includes text, "- ABOUT ALEX."
    assert_includes text, "Alex McRitchie is the founder of McRitchie Studio", "the profile below the doc's rule is printed"
    assert_includes text, "he is married and has a daughter", "the family line Alex allowed"
    assert_includes text, "Speak ABOUT Alex, in the third person"
    assert_includes text, "never claim to\n    be him"
    assert_includes text, "Politely decline anything more about his family"
    assert_includes text, "answer it with NO intake card"
    assert_includes text, "Alex hasn't shared that here", "an unrecorded view is declined, never invented"
    assert_operator text.index("THIS IS A /build INTAKE CHAT"), :<, text.index("- ABOUT ALEX."), "the profile follows the playbook"
  end

  test "the doc's header, citations and TODOs never reach the prompt" do
    text = prompt({ "intake" => INTAKE })

    refute_includes text, "Alex: edit freely", "only the part below the rule is printed"
    refute_includes text, "Source:", "citations are HTML comments, stripped"
    refute_includes text, "TODO", "Alex's TODOs stay in the file"
  end

  test "the printed profile stays inside its budget" do
    block = AgentMailbox::ContextBuilder.new(soul: "ray", message: {}, context: { "intake" => INTAKE },
                                             repo_root: Rails.root.to_s).about_alex_block
    profile = block.split("The profile (Alex's own, written for visitors):\n", 2).last
    assert_operator profile.length, :<=, AgentMailbox::ContextBuilder::ABOUT_ALEX_BUDGET + profile.lines.size * 2
    refute_includes profile, AgentMailbox::ContextBuilder::CUT, "the shipped profile fits without a cut"
  end

  test "a profile over budget is cut, and a missing one falls back to one line" do
    Dir.mktmpdir do |root|
      path = File.join(root, AgentMailbox::ContextBuilder::ABOUT_ALEX_DOC)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# head\n\n---\n\n#{'x' * 4000}\n")
      assert_includes prompt({ "intake" => INTAKE }, repo_root: root), AgentMailbox::ContextBuilder::CUT

      File.delete(path)
      assert_includes prompt({ "intake" => INTAKE }, repo_root: root), "Alex has not written his profile yet"
    end
  end

  test "no /build intake, no profile" do
    text = prompt({ "audience" => { "role" => "public" } })
    refute_includes text, "ABOUT ALEX"
    refute_includes text, "married"
  end
end
