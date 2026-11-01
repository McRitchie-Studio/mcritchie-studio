# frozen_string_literal: true

require "json"
require_relative "agent_scope"
require_relative "agent_mailbox"

module AgentMailbox
  module Scopes
    # The tools of ONE scoped run, served over MCP's stdio transport
    # (newline-delimited JSON-RPC 2.0) to the `claude -p` the dispatcher started
    # for an owner's Slack message (bin/agent-scope-mcp; Grant#mcp_config).
    # Claude has no built-in tool in that run, so these four are all it can do:
    #
    #   lookup        a bounded board read from LOOKUPS, through the holder-only
    #                 endpoint (GET /api/v1/agent_messages/:id/lookup)
    #   run_command   one of the scope's commands: its exact argv prefix plus
    #                 checked arguments, run with no shell under the child
    #                 environment's allow-list (AgentMailbox.run_command)
    #   read_file     a file the scope's paths allow and deny_paths does not
    #   list_files    the files the scope's paths allow
    #
    # Every result is capped (output_limit) and scrubbed (Redact) before Claude
    # sees it. A refusal is a tool error the model reads, never a crash. Nothing
    # here writes: the board endpoint is a GET, the commands are reads, and the
    # file tools open files read-only.
    class Server
      PROTOCOL = "2025-06-18"
      LIST_LIMIT = 300

      def initialize(soul:, message_id:, worker:, repo_root:, config: nil, client: nil, runner: nil,
                     input: $stdin, output: $stdout)
        @config = config || Config.load(repo_root)
        @scope = @config.scope_for(soul) || raise(ConfigError, "#{soul} has no scope")
        @message_id = Integer(message_id)
        @worker = worker.to_s
        @repo_root = File.realpath(repo_root)
        @client = client
        @runner = runner || AgentMailbox.method(:run_command)
        @input = input
        @output = output
      end

      def run
        @input.each_line do |line|
          request = begin
            JSON.parse(line)
          rescue JSON::ParserError
            write(error(nil, -32_700, "parse error"))
            next
          end
          reply = handle(request)
          write(reply) if reply
        end
      end

      # One JSON-RPC request in, its response out (nil for a notification).
      def handle(request)
        return error(nil, -32_600, "invalid request") unless request.is_a?(Hash)

        id = request["id"]
        case request["method"]
        when "initialize"
          result(id, "protocolVersion" => request.dig("params", "protocolVersion") || PROTOCOL,
                     "capabilities" => { "tools" => {} },
                     "serverInfo" => { "name" => "agent-scope", "version" => "1" })
        when "tools/list" then result(id, "tools" => tools)
        when "tools/call" then result(id, call_tool(request.dig("params", "name"), request.dig("params", "arguments") || {}))
        when "ping" then result(id, {})
        else
          id.nil? ? nil : error(id, -32_601, "method not found")
        end
      end

      def tools
        list = []
        if @scope.lookups.any?
          list << { "name" => "lookup",
                    "description" => "Read the board. One of: #{@scope.lookups.map { |n| "#{n} (#{LOOKUPS[n]['what']})" }.join('; ')}.",
                    "inputSchema" => { "type" => "object", "required" => [ "name" ],
                                       "properties" => { "name" => { "type" => "string", "enum" => @scope.lookups },
                                                         "params" => { "type" => "object",
                                                                       "description" => lookup_params_doc } } } }
        end
        if @scope.commands.any?
          list << { "name" => "run_command",
                    "description" => "Run one read-only command: #{@scope.commands.map { |c| "#{c.name} (#{c.what})" }.join('; ')}.",
                    "inputSchema" => { "type" => "object", "required" => [ "name" ],
                                       "properties" => { "name" => { "type" => "string", "enum" => @scope.commands.map(&:name) },
                                                         "args" => { "type" => "array", "items" => { "type" => "string" } } } } }
        end
        if @scope.paths.any?
          list << { "name" => "read_file",
                    "description" => "Read a file in the hub checkout. Allowed: #{@scope.paths.join(', ')}.",
                    "inputSchema" => { "type" => "object", "required" => [ "path" ],
                                       "properties" => { "path" => { "type" => "string" },
                                                         "offset" => { "type" => "integer", "description" => "byte to start at" } } } }
          list << { "name" => "list_files",
                    "description" => "List the files read_file may open, optionally under one folder.",
                    "inputSchema" => { "type" => "object",
                                       "properties" => { "under" => { "type" => "string" } } } }
        end
        list
      end

      # A tool's MCP result: text content, isError on a refusal.
      def call_tool(name, args)
        args = args.is_a?(Hash) ? args : {}
        text = case name.to_s
               when "lookup" then lookup(args["name"], args["params"])
               when "run_command" then run_command(args["name"], args["args"])
               when "read_file" then read_file(args["path"], args["offset"])
               when "list_files" then list_files(args["under"])
               else raise Refused, "no tool named #{name.to_s[0, 40].inspect}"
               end
        { "content" => [ { "type" => "text", "text" => finish(text) } ] }
      rescue Refused, ConfigError => e
        { "content" => [ { "type" => "text", "text" => "refused: #{e.message}" } ], "isError" => true }
      rescue ApiError => e
        { "content" => [ { "type" => "text", "text" => "the board did not answer: #{Redact.call(e.message)[0, 300]}" } ],
          "isError" => true }
      rescue StandardError => e
        { "content" => [ { "type" => "text", "text" => "the tool failed (#{e.class})" } ], "isError" => true }
      end

      def lookup(name, params)
        raise Refused, "this scope has no lookups" if @scope.lookups.empty?

        name, checked = Scopes.check_lookup(name, params, allowed: @scope.lookups)
        answer = client.lookup(@message_id, worker: @worker, name: name, params: checked)
        answer.dig("data", "text").to_s
      end

      def run_command(name, extra)
        command = @scope.command(name) || raise(Refused, "no command named #{name.to_s[0, 40].inspect} in this scope")
        argv = command.argv_for(extra)
        output, status, = @runner.call(argv, stdin: nil, timeout: @config.tool_timeout, chdir: @repo_root)
        exit_text = status.nil? ? "timed out after #{@config.tool_timeout}s" : "exit #{status}"
        "$ #{argv.join(' ')}  (#{exit_text})\n#{output}"
      end

      def read_file(path, offset)
        full, rel = resolve!(path)
        raise Refused, "#{rel} is not a file" unless File.file?(full)

        start = offset.to_i.clamp(0, File.size(full))
        data = File.open(full, "rb") do |f|
          f.seek(start)
          f.read(@config.read_limit).to_s
        end
        raise Refused, "#{rel} is not text" if data.include?("\0")

        text = data.force_encoding(Encoding::UTF_8).scrub
        rest = File.size(full) - start - data.bytesize
        more = rest.positive? ? "\n…[#{rest} more bytes; read_file with offset #{start + data.bytesize}]" : ""
        "#{rel} (#{File.size(full)} bytes, from byte #{start})\n#{text}#{more}"
      end

      def list_files(under)
        prefix = under.to_s.sub(%r{\A\./}, "").chomp("/")
        raise Refused, "list_files takes a folder inside the checkout" if prefix.start_with?("/") || prefix.split("/").include?("..")

        files = @scope.paths.flat_map { |glob| Dir.glob(glob, File::FNM_DOTMATCH, base: @repo_root) }
                      .uniq.sort
                      .select { |rel| prefix.empty? || rel.start_with?("#{prefix}/") || rel == prefix }
                      .select { |rel| allowed_path?(rel) && File.file?(File.join(@repo_root, rel)) }
        return "(no files)" if files.empty?

        shown = files.first(LIST_LIMIT)
        more = files.size > shown.size ? "\n…and #{files.size - shown.size} more; narrow with `under`" : ""
        "#{shown.join("\n")}#{more}"
      end

      # [absolute path, path relative to the checkout] for a file the scope
      # allows, or Refused. The REAL path is what is checked: a symlink that
      # points out of the checkout, or into a denied file, is refused.
      def resolve!(path)
        given = path.to_s.strip
        raise Refused, "read_file needs a path" if given.empty?
        raise Refused, "paths are relative to the hub checkout" if given.start_with?("/", "~")
        raise Refused, "a path may not climb out with .." if given.split("/").include?("..")

        full = File.realpath(File.join(@repo_root, given))
        raise Refused, "#{given} is outside the checkout" unless full.start_with?(File.join(@repo_root, ""))

        rel = full.delete_prefix(File.join(@repo_root, ""))
        raise Refused, "#{rel} is not in this scope's paths" unless allowed_path?(rel)

        [ full, rel ]
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Refused, "#{given} does not exist"
      end

      def allowed_path?(rel)
        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
        return false if @config.deny_paths.any? { |glob| File.fnmatch?(glob, rel, flags) }

        @scope.paths.any? { |glob| File.fnmatch?(glob, rel, flags) }
      end

      private

      def lookup_params_doc
        @scope.lookups.map do |n|
          params = LOOKUPS[n]["params"]
          next "#{n}: none" if params.empty?

          "#{n}: " + params.map do |k, r|
            r["type"] == "integer" ? "#{k} #{r['min']}-#{r['max']} (default #{r['default']})" : "#{k}#{' (required)' if r['required']}"
          end.join(", ")
        end.join("; ")
      end

      def finish(text)
        out = Redact.call(text.to_s)
        limit = @config.output_limit
        out.length > limit ? "#{out[0, limit]}\n…[cut at #{limit} characters]" : out
      end

      def client
        @client ||= Client.new
      end

      def result(id, value) = { "jsonrpc" => "2.0", "id" => id, "result" => value }
      def error(id, code, message) = { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }

      def write(obj)
        @output.write("#{JSON.generate(obj)}\n")
        @output.flush
      end
    end
  end
end
