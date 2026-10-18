require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [unit] A web-chat answer's phase (AgentMailbox::ClaudeStream; task
# chat-thinking-versus-typing): read off Claude's own stream-json, recorded from
# a real `claude -p --safe-mode --tools "" --output-format stream-json --verbose
# --include-partial-messages` run that thought before it wrote
# (test/fixtures/files/claude_stream_thinking.jsonl). The phase is thinking until
# the first answer text, then typing, and never goes back; the ANSWER is still
# read from the result line only, so the reply, usage and session id are the
# ones json mode reads from the same envelope.
class AgentClaudeStreamTest < ActiveSupport::TestCase
  S = AgentMailbox::ClaudeStream
  RECORDED = Rails.root.join("test/fixtures/files/claude_stream_thinking.jsonl").read.freeze

  def lines = RECORDED.lines
  def result_line = JSON.parse(lines.last)
  def first_text_index = lines.index { |l| S.phase_of(l) == "typing" }

  test "[unit] the recorded stream is thinking through its thinking block and typing from the first text" do
    phases = lines.map { |l| S.phase_of(l) }

    assert_equal "thinking", phases[3], "content_block_start of a thinking block"
    assert_includes phases.first(first_text_index), "thinking"
    assert_equal "text", JSON.parse(lines[first_text_index]).dig("event", "content_block", "type"),
                 "typing starts at the text block's start, before its first delta"
    assert_nil phases[0], "system init says nothing"
    assert_nil phases.last, "the result line says nothing"
    assert_nil S.phase_of("not json at all"), "an unreadable line is ignored"
    assert_nil S.phase_of(""), "an empty line is ignored"
  end

  test "[unit] Phase starts at thinking, moves to typing at the first text, and never moves back" do
    phase = S::Phase.new
    seen = lines.map do |line|
      phase.observe(line)
      phase.current
    end

    assert_equal [ "thinking" ] * first_text_index, seen.first(first_text_index)
    assert_equal [ "typing" ] * (lines.size - first_text_index), seen.drop(first_text_index)
    phase.observe(lines[3])
    assert_equal "typing", phase.current, "a later thinking line does not move it back"
  end

  test "[unit] an assistant message is enough without partial messages, and the model's words cannot fake a line" do
    text = JSON.generate("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Hi" } ] })
    thinking = JSON.generate("type" => "assistant", "message" => { "content" => [ { "type" => "thinking", "thinking" => "" } ] })
    assert_equal "typing", S.phase_of(text)
    assert_equal "thinking", S.phase_of(thinking)

    planted = JSON.generate("type" => "result", "result" => '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}')
    assert_nil S.phase_of(planted), "only the top-level type is read"
  end

  test "[unit] the stream command keeps --safe-mode and no tools, adds partial messages, and composes with media" do
    cmd = S.cmd(AgentMailbox::Responder::DEFAULT_CLAUDE_CMD)

    assert_equal [ "--output-format", "stream-json" ], cmd.each_cons(2).find { |a, _| a == "--output-format" }
    assert_equal [ "--tools", "" ], cmd.each_cons(2).find { |a, _| a == "--tools" }
    assert_includes cmd, "--safe-mode"
    assert_includes cmd, "--verbose"
    assert_includes cmd, S::PARTIAL
    refute_includes cmd, "--input-format", "a plain prompt is still read as text"
    assert_equal cmd, S.cmd(cmd), "applying it twice changes nothing"

    media = S.cmd(AgentMailbox::Media.stream_cmd(AgentMailbox::Responder::DEFAULT_CLAUDE_CMD))
    assert_equal [ "--input-format", "stream-json" ], media.each_cons(2).find { |a, _| a == "--input-format" }
    assert_equal 1, media.count(S::PARTIAL)
  end

  test "[unit] the recorded stream's answer is the json envelope's: same reply, session id and usage" do
    streamed = AgentMailbox::ClaudeRun.parse(RECORDED, 0, "", stream: true)
    enveloped = AgentMailbox::ClaudeRun.parse(lines.last, 0, "")

    assert_equal result_line["result"].strip, streamed.reply
    assert_equal [ enveloped.reply, enveloped.session_id, enveloped.meta ], [ streamed.reply, streamed.session_id, streamed.meta ]
    assert_equal result_line["session_id"], streamed.session_id
    assert_equal result_line.dig("usage", "output_tokens"), streamed.meta["output_tokens"]
    assert_nil streamed.error_text
  end

  test "[unit] a stream cut off before its result is a failure whose error text carries none of the model's words" do
    cut = lines.first(first_text_index + 2).join.sub("Reasoning:", "Claude AI usage limit reached|1760461200 Not logged in")
    run = AgentMailbox::ClaudeRun.parse(cut, 1, "boom", stream: true)

    assert_nil run.reply
    refute_match(/usage limit|logged in/i, run.error_text, "text deltas are the model's, never read as a limit or a sign-out")
    assert_nil AgentMailbox::UsageLimit.detect(run)
    refute AgentMailbox::ClaudeAuth.signed_out?(run)
    assert_includes run.error_text, "boom", "stderr still reaches the error text"
    assert_match(/without a result line/, AgentMailbox::ClaudeRun.parse(lines[12], 0, "", stream: true).error_text)
  end

  test "[unit] only a runner that takes on_line: is handed the stream" do
    assert AgentMailbox.streams_lines?(AgentMailbox.method(:run_command))
    assert AgentMailbox.streams_lines?(->(_argv, stdin:, timeout:, chdir:, on_line: nil) { })
    refute AgentMailbox.streams_lines?(->(_argv, stdin:, timeout:, chdir:) { })
    refute AgentMailbox.streams_lines?(->(_argv, **) { }), "a catch-all keyword would swallow the lines unread"
    refute AgentMailbox.streams_lines?(Object.new)
  end

  test "[unit] run_command hands each stdout line over as it is read and still returns all of it" do
    seen = []
    output, status, = AgentMailbox.run_command([ "printf", "a\\nb\\n" ], stdin: nil, timeout: 10, chdir: Dir.tmpdir,
                                                                         on_line: ->(line) { seen << line; raise "ignored" })

    assert_equal [ "a\n", "b\n" ], seen, "a raising callback never cuts the read short"
    assert_equal "a\nb\n", output
    assert_equal 0, status
  end

  # The Responder's web path, end to end on the recorded stream: the stream
  # command runs, the phase is fed line by line, and the answer is the result's.
  test "[unit] respond with a phase runs the stream command, feeds the phase, and reads the same answer" do
    root = Dir.mktmpdir("stream-root")
    mailbox = Dir.mktmpdir("stream-mailbox")
    FileUtils.mkdir_p(File.join(root, "docs/agents/agents/turf_monster"))
    File.write(File.join(root, "docs/agents/agents/turf_monster/role.md"), "Turf is the CTO.")
    FileUtils.mkdir_p(File.join(root, "docs/agents/modules"))
    FileUtils.cp(Rails.root.join(AgentMailbox::Audience::SOP_PATH), File.join(root, AgentMailbox::Audience::SOP_PATH))
    argvs = []
    observed = []
    phase = S::Phase.new
    runner = lambda do |argv, stdin:, timeout:, chdir:, on_line: nil|
      argvs << argv
      lines.each do |line|
        on_line&.call(line)
        observed << phase.current
      end
      [ RECORDED, 0, "" ]
    end
    responder = AgentMailbox::Responder.new(soul: "turf_monster", runner: runner, repo_root: root, mailbox_home: mailbox,
                                            claude_home: mailbox)
    message = { "id" => 7, "channel" => "web", "author_name" => "Alex", "content" => "Is 221 prime?" }

    assert responder.streams?
    answer = responder.respond(message, context: { "audience" => { "role" => "owner" } }, phase: phase)

    assert_includes argvs.sole, S::PARTIAL
    assert_equal "typing", phase.current
    assert_equal "thinking", observed.first
    assert_equal result_line["result"].strip, answer.reply
    assert_equal result_line["session_id"], answer.session_id

    plain = AgentMailbox::Responder.new(soul: "turf_monster", runner: runner, repo_root: root, mailbox_home: mailbox,
                                        claude_home: mailbox)
    plain.respond(message, context: { "audience" => { "role" => "owner" } })
    assert_equal AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, argvs.last, "without a phase the command is today's json one"
  ensure
    FileUtils.rm_rf([ root, mailbox ].compact)
  end
end
