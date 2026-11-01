require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] A spoken /chat message in the dispatcher's prompt (task
# talk-to-alex-by-voice): the row's envelope.voice becomes a "Spoken by" line
# INSIDE the fence (a person's name is their own text) and one code-written rule
# outside it, so Alex knows who spoke. A typed message carries neither.
class AgentContextBuilderVoiceTest < ActiveSupport::TestCase
  FENCE = "untrusted-voice01".freeze
  OWNER = AgentMailbox::Audience.new(role: "owner")

  setup do
    @root = Dir.mktmpdir("ctx-voice")
    FileUtils.mkdir_p(File.join(@root, "docs/agents/agents/alex"))
    File.write(File.join(@root, "docs/agents/agents/alex/role.md"), "Alex sells.")
    FileUtils.mkdir_p(File.join(@root, "docs/agents/modules"))
    FileUtils.cp(Rails.root.join(AgentMailbox::Audience::SOP_PATH), File.join(@root, AgentMailbox::Audience::SOP_PATH))
  end

  teardown { FileUtils.rm_rf(@root) }

  def prompt(voice)
    message = { "id" => 7, "channel" => "web", "author_name" => "Alex McRitchie", "content" => "what's on today?",
                "envelope" => { "via" => "agent_chat", "voice" => voice }.compact }
    AgentMailbox::ContextBuilder.new(soul: "alex", message: message, context: nil, repo_root: @root, fence: FENCE,
                                     audience: OWNER).prompt
  end

  def fenced_message(text) = text[/== THE MESSAGE TO ANSWER.*\z/m]
  def outside_fences(text) = text.gsub(%r{<#{FENCE}>.*?</#{FENCE}>}m, "")

  test "a recognised voice is named inside the fence, with the rule outside it" do
    text = prompt("speaker" => "Alex McRitchie", "score" => 0.91, "check" => "matched", "duration_ms" => 2100)

    assert_includes fenced_message(text), "<#{FENCE}>\nFrom: Alex McRitchie\nSpoken by: Alex McRitchie (voice recognised)\nwhat's on today?"
    assert_includes outside_fences(text), "The sender SPOKE this message"
    refute_includes outside_fences(text), "Spoken by: Alex McRitchie", "the name never leaves the fence"
  end

  test "an unrecognised voice says Someone new and not recognised" do
    text = prompt("speaker" => "Someone new", "score" => 0.2, "check" => "below_threshold", "duration_ms" => 900)

    assert_includes fenced_message(text), "Spoken by: Someone new (voice not recognised)"
    assert_includes outside_fences(text), "do not assume the account holder is the one talking"
  end

  test "a blank or over-long speaker is cut, and a typed message has no voice lines" do
    assert_includes prompt("speaker" => "  ", "check" => "no_profile"), "Spoken by: Someone new (voice not recognised)"
    long = prompt("speaker" => "x" * 300, "check" => "matched")
    assert_includes long, "Spoken by: #{'x' * 100} (voice recognised)"

    typed = prompt(nil)
    refute_includes typed, "Spoken by"
    refute_includes typed, "SPOKE"
  end
end
