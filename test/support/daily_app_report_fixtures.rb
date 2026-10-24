require "socket"

# Fixtures for the daily app report tests (docs/agents/system/daily-app-report.md):
# catalog entries, health bodies in the source contract's shape, and a tiny
# real HTTP server on 127.0.0.1 so Net::HTTP is exercised across a socket.
# Nothing reaches a real app or Discord.
module DailyAppReportFixtures
  def app_entry(slug, name: slug.titleize, url: "https://#{slug}.example.test")
    AppCatalog::Entry.new(slug: slug, name: name, emoji: "x", color: "#000000", tier: "product", status: "active",
                          port: nil, repo: nil, heroku_app: nil, production_url: url, qa_url: nil, engine: true,
                          hosted: true, workspace: nil, database: true, backups: true, restore_drilled: nil,
                          description: "")
  end

  def health_body(app: "Turf Monster", signups: 0, errors: 0, groups: [], contacts: nil)
    sections = [ { "key" => "signups", "title" => "Signups", "count" => signups, "failure" => nil },
                 { "key" => "errors", "title" => "Errors", "count" => errors, "failure" => nil } ]
    sections << { "key" => "contacts", "title" => "Contact messages", "count" => contacts, "failure" => nil } if contacts
    { "schema" => 1, "app" => app, "engine_version" => "0.108.0",
      "window" => { "begin" => "2026-10-14T07:00:00-06:00", "end" => "2026-10-15T07:00:00-06:00",
                    "label" => "Oct 14, 7:00 AM to Oct 15, 7:00 AM MDT" },
      "quiet" => signups.zero? && errors.zero? && contacts.to_i.zero?,
      "sections" => sections, "error_kinds" => groups.size,
      "error_groups" => groups.map do |klass, message, count|
        { "error_class" => klass, "message" => message, "count" => count,
          "first_seen" => "2026-10-14T08:00:00-06:00", "last_seen" => "2026-10-15T06:00:00-06:00" }
      end }
  end

  # A fetcher double: url => body Hash, or an Exception to raise. Records calls.
  class FakeFetcher
    attr_reader :calls

    def initialize(answers) = (@answers = answers; @calls = [])

    def fetch(url, token:, ending:)
      @calls << { url: url, token: token, ending: ending }
      answer = @answers.fetch(url) { raise "unexpected fetch #{url}" }
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  # A one-thread HTTP/1.1 server. `routes` maps a path to [status, body] or a
  # callable(request_line, headers) returning one; :hang never answers.
  class TinyServer
    attr_reader :requests, :port

    def initialize(routes)
      @routes = routes
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { loop { serve(@server.accept) } rescue nil }
    end

    def url = "http://127.0.0.1:#{@port}"

    def close
      @thread.kill
      @server.close
    end

    private

    def serve(socket)
      line = socket.gets.to_s
      headers = {}
      while (header = socket.gets) && header != "\r\n"
        name, value = header.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      path, query = line.split(" ")[1].to_s.split("?", 2)
      @requests << { path: path, query: URI.decode_www_form(query.to_s).to_h, headers: headers }
      answer = @routes.fetch(path, [ 404, "{}" ])
      return sleep(5) if answer == :hang

      status, body = answer
      socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close unless socket.closed?
    end
  end
end
