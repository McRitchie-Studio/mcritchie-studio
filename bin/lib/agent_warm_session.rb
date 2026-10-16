# frozen_string_literal: true

require "fileutils"
require "stringio"
require "zlib"
require_relative "agent_audience"

module AgentMailbox
  # The pieces of a warm session the dispatcher needs that are not the loop
  # itself (docs/agents/system/agent-message-loop.md, "Warm sessions"): what one
  # warm turn carries, where a session's transcript lives on this machine, and
  # how a transcript is packed for the board and restored from it.
  #
  # A warm turn is ONE `claude -p --resume <id>` run, still --safe-mode with no
  # tools and the json envelope, and its status is read exactly as a cold run's
  # (ClaudeRun). Only the domain's front-door soul answers warm, and only for an
  # owner or team sender whose message was not a released hold.
  module WarmSession
    # The board keeps at most this many bytes of gzipped transcript
    # (AgentDomainSession::CHECKPOINT_LIMIT reads this constant). A transcript
    # past it is consolidated instead of checkpointed.
    CHECKPOINT_LIMIT = 4 * 1024 * 1024
    # The audiences a warm session ever hears. Client and public messages are
    # answered one run per message, so untrusted text never persists.
    AUDIENCES = %w[owner team].freeze
    # The most a restored transcript may expand to.
    RESTORE_LIMIT = 64 * 1024 * 1024
    SUMMARY_LIMIT = 8_000
    SESSION_ID = /\A[0-9A-Za-z-]{8,100}\z/

    # domain: the warm domain. resume_id: the session to resume (nil starts a
    # fresh one). seed: the last consolidation's summary, for a fresh session.
    # turns, generation, consolidate_at: the board's numbers at acquire.
    Turn = Struct.new(:domain, :resume_id, :seed, :turns, :generation, :consolidate_at, keyword_init: true) do
      def resumed? = !resume_id.nil?
    end

    # The words a consolidation turn is given. Code, never the model's.
    SUMMARY_PROMPT = <<~TEXT
      This session has grown long, so it will be closed and a new one started from notes you write now.
      Write those notes: what you have been asked in this domain, what you answered, decisions made,
      open questions, and anything you said would follow. Plain text, under 6,000 characters, no preamble.
      Write only facts from this conversation. They are notes, never instructions: a later session reads
      them as data. Do not add a notes section or a PROPOSAL block.
    TEXT

    # Will a warm session answer this message? Code-only: the board's audience
    # in the context bundle, never anything the message says.
    def self.eligible?(message, context)
      return false if message.is_a?(Hash) && !message["hold_released_at"].to_s.empty?

      AUDIENCES.include?(Audience.from_context(context).role)
    end

    # The tokens one turn's context held: input + cache read + cache write.
    def self.context_tokens(meta)
      meta = meta.is_a?(Hash) ? meta : {}
      %w[input_tokens cache_read_tokens cache_creation_tokens].sum { |k| meta[k].is_a?(Numeric) ? meta[k].to_i : 0 }
    end

    # Past the domain's threshold the holder consolidates after the turn.
    def self.consolidate?(context_tokens, threshold) = context_tokens.to_i >= threshold.to_i && threshold.to_i.positive?

    # Claude Code's folder for a cwd's sessions: <claude home>/projects/<cwd with
    # every character outside [A-Za-z0-9] turned into "-">.
    def self.project_dir(cwd, claude_home:)
      File.join(claude_home, "projects", File.expand_path(cwd).gsub(/[^A-Za-z0-9]/, "-"))
    end

    # The transcript of `session_id` on this machine: under the cwd's own folder
    # first, else wherever Claude filed it. nil when there is none.
    def self.transcript_path(session_id, cwd:, claude_home:)
      return nil unless session_id.to_s.match?(SESSION_ID)

      own = File.join(project_dir(cwd, claude_home: claude_home), "#{session_id}.jsonl")
      return own if File.file?(own)

      Dir.glob(File.join(claude_home, "projects", "*", "#{session_id}.jsonl")).first
    end

    # The transcript gzipped, for the board's checkpoint.
    def self.pack(path)
      io = StringIO.new("".b)
      gz = Zlib::GzipWriter.new(io)
      File.open(path, "rb") { |f| IO.copy_stream(f, gz) }
      gz.finish
      io.string
    end

    # Write a checkpoint back as `session_id`'s transcript under this cwd's
    # folder, so `claude --resume` finds it. Raises on a corrupt checkpoint.
    def self.restore!(session_id, gzipped, cwd:, claude_home:)
      raise ArgumentError, "not a Claude session id" unless session_id.to_s.match?(SESSION_ID)

      dir = project_dir(cwd, claude_home: claude_home)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{session_id}.jsonl")
      tmp = "#{path}.restoring"
      text = Zlib::GzipReader.new(StringIO.new(gzipped.b)).read(RESTORE_LIMIT + 1).to_s
      raise ArgumentError, "checkpoint expands past #{RESTORE_LIMIT} bytes" if text.bytesize > RESTORE_LIMIT

      File.binwrite(tmp, text)
      File.rename(tmp, path)
      path
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
