# frozen_string_literal: true

require "json"

module AgentMailbox
  # A web-chat answer's PHASE, read off Claude's own stream while it runs
  # (docs/agents/system/agent-message-loop.md, "Web chat", typing). The page
  # shows "<Agent> is thinking" until the answer's first words exist, then
  # "<Agent> is typing". `claude -p --output-format json` prints nothing until
  # the run is over, so a web answer runs on stream-json with partial messages
  # (ClaudeStream.cmd) and every stdout line passes through Phase#observe.
  #
  # THE ANSWER IS NOT READ HERE. The reply, usage and session id still come
  # from the stream's `result` line only (ClaudeRun.parse(..., stream: true)),
  # the same object json mode prints. This module only decides which of two
  # words the indicator shows, so a line it cannot read changes nothing.
  #
  # Which lines count, from Claude Code's stream (recorded in
  # test/fixtures/files/claude_stream_thinking.jsonl):
  #   stream_event content_block_start  content_block.type text      typing
  #   stream_event content_block_delta  delta.type         text_delta typing
  #   assistant    message.content[]    type               text      typing
  # A thinking block (content_block_start thinking, thinking_delta) is the
  # thinking the phase starts in. The phase only moves forward: a front-door
  # answer has no tools, so it thinks, then writes, and never thinks again.
  module ClaudeStream
    PARTIAL = "--include-partial-messages"
    PHASES = %w[thinking typing].freeze

    # `cmd` with its output switched to stream-json and partial messages on.
    # Everything else stays as given: --safe-mode, --tools "", --resume, and a
    # media run's --input-format stream-json (Media.stream_cmd, which this
    # composes with in either order). --verbose is the CLI's requirement for
    # stream-json output.
    def self.cmd(cmd)
      argv = cmd.dup
      if (i = argv.index("--output-format"))
        argv[i + 1] = "stream-json"
      else
        argv += %w[--output-format stream-json]
      end
      argv += %w[--verbose] unless argv.include?("--verbose")
      argv += [ PARTIAL ] unless argv.include?(PARTIAL)
      argv
    end

    # "typing" when the line says the answer's text has begun, "thinking" for a
    # thinking block, else nil (system lines, the result, anything unreadable).
    # Only top-level fields are read; the model's words are string values and
    # cannot make a line look like another kind.
    def self.phase_of(line)
      text = line.to_s
      return nil unless text.include?("stream_event") || text.include?("assistant")

      data = JSON.parse(text)
      return nil unless data.is_a?(Hash)

      case data["type"]
      when "stream_event" then event_phase(data["event"])
      when "assistant" then message_phase(data["message"])
      end
    rescue JSON::ParserError
      nil
    end

    def self.event_phase(event)
      return nil unless event.is_a?(Hash)

      block = case event["type"]
              when "content_block_start" then event["content_block"]
              when "content_block_delta" then event["delta"]
              end
      return nil unless block.is_a?(Hash)

      case block["type"]
      when "text", "text_delta" then "typing"
      when "thinking", "thinking_delta", "redacted_thinking" then "thinking"
      end
    end

    def self.message_phase(message)
      content = message.is_a?(Hash) ? message["content"] : nil
      return nil unless content.is_a?(Array)

      types = content.filter_map { |c| c["type"] if c.is_a?(Hash) }
      return "typing" if types.include?("text")

      "thinking" if types.any? { |t| t.to_s.end_with?("thinking") }
    end
    private_class_method :event_phase, :message_phase

    # One run's phase, written by the run's stdout reader thread and read by
    # the dispatcher's main loop (which alone talks to the board). Starts at
    # thinking; moves to typing once and stays.
    class Phase
      def initialize
        @mutex = Mutex.new
        @phase = "thinking"
      end

      def current = @mutex.synchronize { @phase }
      def typing? = current == "typing"

      def observe(line)
        return if typing?

        @mutex.synchronize { @phase = "typing" } if ClaudeStream.phase_of(line) == "typing"
      end

      # The runner's on_line callback.
      def to_proc = method(:observe).to_proc
    end
  end
end
