require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require Rails.root.join("bin/lib/agent_audience").to_s

# [integration] bin/dispatcher's loop under launchd's bare environment.
#
# Regression (2026-10-15): launchd starts the dispatcher with only HOME and PATH
# and no LANG, so Ruby's default external encoding is US-ASCII, and every answer
# run raised "invalid byte sequence in US-ASCII" reading a role doc with an em
# dash; #67 and #68 dead-lettered. The suite always ran under a UTF-8 locale, so
# nothing caught it. Here a child Ruby runs under exactly that environment
# (HOME and PATH, everything else unset): the real Dispatcher loop and Responder,
# a real child process for the soul's action (a stub bin/task) and for Claude (a
# stub that records its prompt), against an in-memory board. Non-ASCII text sits
# in the role doc, the domain doc, the action's output and the reply.
#
# It runs twice: once through the entry preamble bin/dispatcher runs
# (ProcessEncoding.force_utf8!), and once without it, so each layer of the fix
# (the process default, and the explicit UTF-8 reads) is shown to hold alone.
class AgentDispatcherBareEnvTest < ActiveSupport::TestCase
  LIB = Rails.root.join("bin/lib").to_s
  REPLY = "Two tasks are building — café \u{1F680}".freeze

  # The child: boot under the bare env, optionally run the entry preamble, then
  # drive the real loop until the one message is completed or given back.
  CHILD = <<~'RUBY'.freeze
    lib, root, mode, claude = ARGV
    boot = Encoding.default_external.to_s
    if mode == "entry"
      require File.join(lib, "process_encoding")
      ProcessEncoding.force_utf8!
    end
    require File.join(lib, "agent_dispatcher")

    class Board
      attr_reader :completed, :released

      def initialize
        @queue = [ { "id" => 67, "soul_slug" => "ray", "attempts" => 1, "channel" => "discord",
                     "author_name" => "Alex", "content" => "what is building?" } ]
        @completed = []
        @released = []
      end

      def claim(**) = { "data" => @queue.shift }
      # The owner, so the action runs and the role doc is in GENERAL.
      def context(*, **) = { "data" => { "audience" => { "role" => "owner" } } }
      def renew(*, **) = {}
      def ping(*) = {}

      def complete(id, worker:, response_text:, action_summary:, run: {})
        @completed << { "id" => id, "text" => response_text, "action" => action_summary }
        { "meta" => { "outcome" => "posted" } }
      end

      def release(id, worker:, reason:, code: nil)
        @released << { "id" => id, "reason" => reason }
        {}
      end
    end

    board = Board.new
    disp = AgentMailbox::Dispatcher.new(client: board, souls: %w[ray], worker: "bare-env-1", claude_cmd: [ claude ],
                                        repo_root: root, out: $stderr, sleeper: ->(_) {}, idle_wait: 0, busy_wait: 0,
                                        version: "test")
    500.times do
      disp.tick
      break if (board.completed.any? || board.released.any?) && disp.runs.empty?

      sleep 0.02
    end
    $stdout.write JSON.generate("boot" => boot, "completed" => board.completed, "released" => board.released)
  RUBY

  setup do
    @dir = Dir.mktmpdir("dispatcher-bare-env")
    @root = File.join(@dir, "repo")
    @home = File.join(@dir, "home")
    FileUtils.mkdir_p([ File.join(@root, "docs/agents/agents/ray"), File.join(@root, "config"),
                        File.join(@root, "bin"), @home ])
    File.write(File.join(@root, "docs/agents/agents/ray/role.md"),
               "Ritch orchestrates — the naïve café crowd \u{1F680}.\n")
    File.write(File.join(@root, "config/agent_domains.yml"),
               "domains:\n  studio: { name: \"McRitchie Studio — hub\", doc: docs/studio.md }\nsouls: { ray: studio }\n")
    File.write(File.join(@root, "docs/studio.md"), "The hub — résumé of agents.\n")
    # The real agent-communication SOP (the audience rules), read under the bare env too.
    FileUtils.mkdir_p(File.join(@root, "docs/agents/modules"))
    FileUtils.cp(Rails.root.join(AgentMailbox::Audience::SOP_PATH), File.join(@root, AgentMailbox::Audience::SOP_PATH))
    script(File.join(@root, "bin/task"), "printf 'board \\342\\200\\224 2 building\\n'")
    @prompt = File.join(@dir, "prompt.txt")
    envelope = JSON.generate("type" => "result", "subtype" => "success", "is_error" => false, "result" => REPLY)
    @claude = script(File.join(@dir, "fake-claude"), "cat > #{@prompt.shellescape}\nprintf '%s' #{envelope.shellescape}")
    @child = File.join(@dir, "child.rb")
    File.write(@child, CHILD)
  end

  teardown { FileUtils.rm_rf(@dir) }

  def script(path, body)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  # launchd's environment: HOME and PATH, nothing else (no LANG, no LC_*).
  def run_child(mode)
    env = { "HOME" => @home, "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin" }
    out, err, status = Open3.capture3(env, RbConfig.ruby, @child, LIB, @root, mode, @claude,
                                      unsetenv_others: true, chdir: @root)
    assert status.success?, "the child exited #{status.exitstatus}:\n#{err}"
    JSON.parse(out)
  end

  def assert_answered(result)
    assert_equal "US-ASCII", result["boot"], "the child booted as launchd starts it: no locale, US-ASCII"
    assert_empty result["released"], "the run was not given back: #{result['released'].inspect}"
    assert_equal [ 67 ], result["completed"].map { |c| c["id"] }
    assert_equal REPLY, result["completed"].first["text"]
    prompt = File.read(@prompt, encoding: "UTF-8")
    assert_includes prompt, "Ritch orchestrates — the naïve café crowd \u{1F680}."
    assert_includes prompt, "The hub — résumé of agents."
    assert_includes prompt, "board — 2 building", "the action's non-ASCII output reached the prompt"
    assert_includes prompt, "You are speaking with: owner"
    refute_includes prompt, "could not be loaded", "the SOP's rules were read under the bare env"
  end

  test "through bin/dispatcher's entry preamble, a message whose role doc has non-ASCII text is answered" do
    assert_answered(run_child("entry"))
  end

  test "without the preamble, the explicit UTF-8 reads alone still answer it" do
    assert_answered(run_child("reads_only"))
  end

  test "bin/dispatcher and bin/heartbeat force UTF-8 before they require anything else" do
    %w[bin/dispatcher bin/heartbeat].each do |path|
      requires = File.readlines(Rails.root.join(path), encoding: "UTF-8").grep(/\A\s*require/)
      assert_equal 'require_relative "lib/process_encoding"', requires.first&.strip, "#{path}'s first require"
      source = File.read(Rails.root.join(path), encoding: "UTF-8")
      assert_operator source.index("ProcessEncoding.force_utf8!"), :<, source.index(requires[1]), path
    end
  end
end
