# frozen_string_literal: true

require "socket"

# WHAT A NAME RESOLVES TO, AND WHERE A FETCH REALLY CONNECTS, DECIDED BY THE TEST.
#
# Under a Rails test environment the engine's URL guard resolves nothing, so a
# test that cares where a name points sets the resolver here, and one that cares
# where the HTTP client connects reads it off the socket here. No real DNS and
# no connection leaves this machine.
#
#   with_resolver("cdn.example.com" => ["93.184.216.34"]) do |lookups|
#     with_dials(to: server_port) do |dials|
#       ...
#       assert_equal ["93.184.216.34"], dials
#       assert_equal ["cdn.example.com"], lookups
#     end
#   end
#
# An answer is a list of addresses, `:fail` (the lookup raises, as a dead
# resolver does), or a callable taking the number of times that name has now
# been asked for (so the first answer and the second can differ: a rebind). A
# name the test did not list fails the lookup.
module PinnedFetchWorld
  PUBLIC = "93.184.216.34"
  PUBLIC_V6 = "2606:2800:220:1:248:1893:25c8:1946"

  def with_resolver(answers)
    lookups = []
    Studio::ImageCache.resolver = lambda do |host|
      lookups << host
      answer = answers.fetch(host) { raise SocketError, "getaddrinfo: no test answer for #{host}" }
      answer = answer.call(lookups.count(host)) if answer.respond_to?(:call)
      raise SocketError, "getaddrinfo: test resolver is down" if answer == :fail

      answer
    end
    yield lookups
  ensure
    Studio::ImageCache.resolver = nil
  end

  # Every TCP connection Net::HTTP opens inside the block, as the address it
  # asked for. `to:` is a local port the connection is handed instead (a
  # LocalHttp below); without it every connection is refused, which is enough
  # to read where the client was going.
  def with_dials(to: nil)
    dials = []
    opener = lambda do |address, _port, *_rest, **_options|
      dials << address
      raise Errno::ECONNREFUSED, "test: nothing listens at #{address}" unless to

      TCPSocket.new("127.0.0.1", to)
    end
    TCPSocket.stub(:open, opener) { yield dials }
  end

  # A plain-HTTP server on the loopback, answering by path. `routes` maps a
  # path to [status line, { header => value }, body]. `heads` collects each
  # request's head as it arrived.
  class LocalHttp
    attr_reader :heads

    def initialize(routes)
      @routes = routes
      @heads = Thread::Queue.new
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
    end

    def port = @server.addr[1]

    def close
      @server.close
      @thread.kill
    end

    private

    def serve
      loop do
        conn = @server.accept
        head = +""
        head << conn.readpartial(4096) until head.include?("\r\n\r\n")
        @heads << head
        status, headers, body = @routes.fetch(head[/\AGET (\S+)/, 1]) { ["404 Not Found", {}, ""] }
        lines = headers.merge("Content-Length" => body.bytesize, "Connection" => "close").map { |k, v| "#{k}: #{v}\r\n" }
        conn.write("HTTP/1.1 #{status}\r\n#{lines.join}\r\n#{body}")
        conn.close
      end
    rescue IOError, SystemCallError
      nil
    end
  end

  def with_local_http(routes)
    server = LocalHttp.new(routes)
    yield server
  ensure
    server&.close
  end
end
