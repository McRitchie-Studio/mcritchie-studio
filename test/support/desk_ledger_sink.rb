# frozen_string_literal: true

require "json"
require "socket"

# DeskLedgerSink — a minimal, in-process desk-ledger board for the command tests.
#
# WHY IT EXISTS. `bin/agent-worktree` files its teardown record on the board BEFORE it
# destroys anything, and it FAILS CLOSED: a write it cannot make aborts the teardown. That
# is the whole point of the change that moved the ledger off
# docs/agents/maintenance/delete-later.md (a row written from the primary lands on `main`
# and can never be committed — 166 rows were stranded that way). It also means the command
# tests, which run under the OutboundSeams network floor with TASK_API_BASE pinned at an
# UNROUTABLE address, can no longer complete a teardown at all.
#
# The wrong answer is an env flag that skips the write in tests: a bypass on a destroy path
# is the one thing this design must not have, and a test suite that runs a different code
# path than production is how a fail-closed guard quietly stops being one. So the tests get
# a REAL board instead — this one. The CLI speaks its actual HTTP, mints an actual token,
# and the sink records what it was told, so a test can assert the RECORD rather than
# markdown prose.
#
# It answers exactly the two paths the ledger writes and 404s everything else: a stray
# caller must fail loudly here, not receive a fabricated success.
class DeskLedgerSink
  SECRET = "desk-ledger-sink-secret"
  TOKEN = "desk-ledger-sink-token"

  attr_reader :posts

  def self.start
    new.tap(&:start)
  end

  def initialize
    @posts = []
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    @thread.abort_on_exception = false
    self
  end

  def stop
    @server&.close
    @thread&.kill
  rescue IOError
    nil
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  # The env a spawned bin/ command needs to reach this sink. AGENT_API_SECRET rides along
  # because TaskBoard.agent_secret would otherwise fall through to the repo .env and then
  # 1Password — a metered read, from a test.
  def env = { "TASK_API_BASE" => url, "AGENT_API_SECRET" => SECRET }

  # Every desk record filed at this sink, in order.
  def desks
    @mutex.synchronize { @posts.select { |post| post[:path] == "/api/v1/desk_records" }.map { |post| post[:body]["desk"] } }
  end

  def synced
    @mutex.synchronize { @posts.select { |post| post[:path] == "/api/v1/desk_records/sync" }.map { |post| post[:body]["registry"] } }
  end

  # The record filed for one desk path, or nil.
  def desk_for(worktree_path)
    desks.find { |desk| desk["worktree_path"] == worktree_path }
  end

  private

  def serve
    loop do
      client = @server.accept
      handle(client)
    rescue IOError, Errno::EBADF, Errno::ECONNRESET
      break
    end
  end

  def handle(client)
    request_line = client.gets.to_s
    _method, path, = request_line.split(" ")
    length = 0
    while (line = client.gets)
      break if line.strip.empty?

      length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
    end
    raw = length.positive? ? client.read(length) : ""
    body = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    respond(client, path, body)
  ensure
    client.close rescue nil # rubocop:disable Style/RescueModifier
  end

  def respond(client, path, body)
    case path
    when "/api/v1/auth"
      write(client, 200, { "token" => TOKEN, "expires_at" => (Time.now + 3600).utc.iso8601 })
    when "/api/v1/desk_records", "/api/v1/desk_records/sync"
      @mutex.synchronize { @posts << { path: path, body: body } }
      write(client, 201, { "data" => { "desks" => Array(body.dig("registry", "worktrees")).size, "vanished" => 0 } })
    else
      # Never fabricate a success for a path this sink does not implement.
      write(client, 404, { "error" => "desk ledger sink does not serve #{path}" })
    end
  end

  def write(client, status, payload)
    json = JSON.generate(payload)
    client.print("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
  end
end
