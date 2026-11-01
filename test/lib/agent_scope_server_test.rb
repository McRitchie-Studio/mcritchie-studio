require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/agent_scope_server"

# [unit] AgentMailbox::Scopes::Server, the MCP tool server a scoped run gets
# (bin/agent-scope-mcp): the protocol handshake, the tool list per scope, and
# every refusal: an unlisted command, an argument outside the pattern, a path
# outside the scope, a denied secret file, a symlink out of the checkout, a
# lookup outside the scope or its bounds (refused BEFORE the board is called).
# Results are redacted and capped. A stub runner and client stand in for the
# shell-less command run and the board.
class AgentScopeServerTest < Minitest::Test
  class StubClient
    attr_reader :calls

    def initialize(text: "Board now: building 2.") = (@text = text) && (@calls = [])

    def lookup(id, worker:, name:, params:)
      @calls << [ id, worker, name, params ]
      { "data" => { "text" => @text } }
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir("scope-server"))
    FileUtils.mkdir_p(File.join(@root, "docs/agents/agents/mason"))
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "docs/agents/agents/mason/role.md"), "# Mason\nCOO.\n")
    File.write(File.join(@root, "docs/agents/.env.md"), "AGENT_API_SECRET=leak")
    File.write(File.join(@root, "config/books.yml"), "entities:\n  studio: {}\n")
    File.write(File.join(@root, "config/credentials.yml"), "secret: x")
    @outside = Dir.mktmpdir("outside")
    File.write(File.join(@outside, "secret.md"), "outside")
    File.symlink(File.join(@outside, "secret.md"), File.join(@root, "docs/agents/escape.md"))
    @runs = []
    @runner = lambda do |argv, stdin:, timeout:, chdir:|
      @runs << { argv: argv, stdin: stdin, timeout: timeout, chdir: chdir }
      [ "slack-owner-terminal-scope [building] token=abcdef123456\n", 0, "" ]
    end
    @client = StubClient.new
  end

  def teardown
    FileUtils.rm_rf(@root)
    FileUtils.rm_rf(@outside)
  end

  def config(**defaults)
    AgentMailbox::Scopes::Config.new(
      "defaults" => { "output_limit" => 400, "read_limit" => 64 }.merge(defaults.transform_keys(&:to_s)),
      "deny_paths" => [ "**/.env*", "**/credentials*" ],
      "souls" => {
        "mason" => { "lookups" => %w[error_groups board_status],
                     "commands" => [ { "name" => "task_show", "argv" => %w[bin/task show],
                                       "args" => '\A(?:-v|[a-z0-9][a-z0-9-]{0,80})\z', "max_args" => 2 } ],
                     "paths" => [ "docs/agents/**/*.md", "config/*.yml" ] },
        "quiet" => { "lookups" => %w[board_status] }
      }
    )
  end

  def server(soul: "mason", cfg: config)
    AgentMailbox::Scopes::Server.new(soul: soul, message_id: 7, worker: "dispatcher-mac", repo_root: @root, config: cfg,
                                     client: @client, runner: @runner)
  end

  def call(name, args, srv: server)
    srv.handle("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
               "params" => { "name" => name, "arguments" => args })["result"]
  end

  def text(result) = result["content"].first["text"]

  def test_the_handshake_and_the_tool_list_follow_the_scope
    init = server.handle("jsonrpc" => "2.0", "id" => 0, "method" => "initialize",
                         "params" => { "protocolVersion" => "2025-06-18" })
    assert_equal({ "tools" => {} }, init.dig("result", "capabilities"))
    assert_nil server.handle("jsonrpc" => "2.0", "method" => "notifications/initialized"), "a notification gets no reply"

    names = server.handle("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list").dig("result", "tools").map { |t| t["name"] }
    assert_equal %w[lookup run_command read_file list_files], names
    quiet = server(soul: "quiet").handle("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")
    assert_equal %w[lookup], quiet.dig("result", "tools").map { |t| t["name"] }, "no commands, no paths: no such tools"
  end

  def test_stdio_round_trip
    input = StringIO.new(%({"jsonrpc":"2.0","id":1,"method":"ping"}\nnot json\n))
    output = StringIO.new
    AgentMailbox::Scopes::Server.new(soul: "mason", message_id: 7, worker: "w", repo_root: @root, config: config,
                                     client: @client, runner: @runner, input: input, output: output).run
    lines = output.string.lines.map { |l| JSON.parse(l) }
    assert_equal({}, lines[0]["result"])
    assert_equal(-32_700, lines[1].dig("error", "code"))
  end

  def test_a_listed_command_runs_its_exact_argv_with_no_shell_and_redacted_output
    result = call("run_command", { "name" => "task_show", "args" => %w[slack-owner-terminal-scope -v] })
    refute result["isError"]
    assert_equal [ { argv: %w[bin/task show slack-owner-terminal-scope -v], stdin: nil, timeout: 45, chdir: @root } ], @runs
    assert_includes text(result), "token=[redacted]"
    refute_includes text(result), "abcdef123456"
  end

  def test_an_unlisted_command_or_a_bad_argument_never_runs
    [ { "name" => "bash", "args" => [ "-c", "ls" ] },
      { "name" => "task_show", "args" => [ "x; cat ~/.ssh/id_rsa" ] },
      { "name" => "task_show", "args" => [ "$(op read op://Agents/x/y)" ] },
      { "name" => "task_show", "args" => [ "--json" ] },
      { "name" => "task_show", "args" => %w[a b c] } ].each do |args|
      result = call("run_command", args)
      assert result["isError"], args.inspect
      assert_match(/\Arefused: /, text(result))
    end
    assert_empty @runs, "nothing ran"
    assert call("Bash", { "command" => "ls" })["isError"], "no tool by any other name"
  end

  def test_read_file_reads_only_allowed_paths
    ok = call("read_file", { "path" => "docs/agents/agents/mason/role.md" })
    refute ok["isError"]
    assert_includes text(ok), "COO."
    assert_includes text(call("read_file", { "path" => "config/books.yml" })), "studio"

    { "docs/agents/.env.md" => /not in this scope/, "config/credentials.yml" => /not in this scope/,
      "docs/agents/escape.md" => /outside the checkout/, "/etc/passwd" => /relative/, "~/.ssh/id_rsa" => /relative/,
      "docs/../config/../../x" => /climb/, "app/models/user.rb" => /not in this scope/, "config/master.key" => /not in this scope/,
      "docs/agents/nope.md" => /does not exist/ }.each do |path, why|
      result = call("read_file", { "path" => path })
      assert result["isError"], path
      assert_match why, text(result), path
    end
  end

  def test_read_file_pages_a_long_file_and_list_files_shows_only_readable_files
    File.write(File.join(@root, "docs/agents/long.md"), "a" * 100)
    first = text(call("read_file", { "path" => "docs/agents/long.md" }))
    assert_match(/read_file with offset 64/, first)
    assert_match(/from byte 64/, text(call("read_file", { "path" => "docs/agents/long.md", "offset" => 64 })))

    listed = text(call("list_files", {})).lines.map(&:strip)
    assert_includes listed, "docs/agents/agents/mason/role.md"
    assert_includes listed, "config/books.yml"
    refute_includes listed, "docs/agents/.env.md"
    refute_includes listed, "config/credentials.yml"
    assert_equal [ "config/books.yml" ], text(call("list_files", { "under" => "config" })).lines.map(&:strip)
    assert call("list_files", { "under" => "../" })["isError"]
  end

  def test_a_lookup_is_checked_before_the_board_is_called
    ok = call("lookup", { "name" => "error_groups", "params" => { "days" => 2 } })
    refute ok["isError"]
    assert_equal [ [ 7, "dispatcher-mac", "error_groups", { "days" => 2 } ] ], @client.calls

    [ { "name" => "books_month", "params" => { "entity" => "studio", "month" => "2026-09" } },
      { "name" => "error_groups", "params" => { "days" => 99 } },
      { "name" => "error_groups", "params" => { "where" => "1=1" } } ].each do |args|
      assert call("lookup", args)["isError"], args.inspect
    end
    assert_equal 1, @client.calls.size, "a refused lookup never reaches the board"
  end

  def test_results_are_capped
    @client = StubClient.new(text: "x " * 1000)
    out = text(call("lookup", { "name" => "board_status" }))
    assert_operator out.length, :<, 460
    assert_match(/cut at 400 characters/, out)
  end

  def test_a_board_failure_is_a_tool_error_without_the_credential
    failing = Object.new
    def failing.lookup(*, **) = raise(AgentMailbox::ApiError, "GET /x -> HTTP 500: Bearer abcdefghijklmnopqrstu")
    srv = AgentMailbox::Scopes::Server.new(soul: "mason", message_id: 7, worker: "w", repo_root: @root, config: config,
                                           client: failing, runner: @runner)
    result = call("lookup", { "name" => "board_status" }, srv: srv)
    assert result["isError"]
    refute_includes text(result), "abcdefghijklmnopqrstu"
  end

  def test_a_soul_with_no_scope_cannot_start_a_server
    assert_raises(AgentMailbox::Scopes::ConfigError) { server(soul: "avi") }
  end
end
