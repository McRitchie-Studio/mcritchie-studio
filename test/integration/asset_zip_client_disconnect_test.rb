# frozen_string_literal: true

require "test_helper"
require "socket"
require "net/http"
require "puma"
require "puma/server"
require "puma/log_writer"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [integration] The alt video asset zip (piece 17) when the browser goes away
# mid-download (piece 20), through a REAL Puma server and a real TCP socket,
# because the error a closed client raises exists only there: Puma 7 writes an
# enumerable body inside body.each, and a write to a reset socket raises
# Puma::ConnectionError ("Socket timeout writing data") back up through the
# zip into the Writer's sink. Rack::Test has no socket, so it cannot show this.
#
# The download must stop at once: no further file is fetched, nothing lands in
# ErrorLog (a disconnect is not an error), and the Puma thread is freed.
class AssetZipClientDisconnectTest < ActionDispatch::IntegrationTest
  # Yields 8 MB per entry in 256 KB pieces, far past any socket buffer, and
  # records every entry it starts and the error a yield raised. After the
  # first piece it waits for the test to reset the client, so the disconnect
  # always lands inside the first file.
  class GatedFetcher
    PIECE = ("x" * 262_144).b

    attr_reader :started, :raised

    def initialize(gate)
      @gate = gate
      @started = []
      @raised = nil
    end

    def each_chunk(entry)
      @started << entry.path
      32.times do |i|
        yield PIECE
        @gate.pop(timeout: 15) if @started.size == 1 && i.zero?
      rescue Exception => e # rubocop:disable Lint/RescueException -- recording what the sink raised
        @raised ||= e
        raise
      end
    end
  end

  setup do
    @video = LetteredVideo.seed!
    @alt = @video.alt_videos.first
    @gate = Thread::Queue.new
    @fetcher = GatedFetcher.new(@gate)
    @previous_fetcher = MusicVideos::AssetZip.fetcher
    MusicVideos::AssetZip.fetcher = @fetcher
    @server = Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 1, log_writer: Puma::LogWriter.null)
    @server.add_tcp_listener("127.0.0.1", 0)
    @server.run
    @port = @server.connected_ports.first
  end

  teardown do
    @server&.stop(true)
    MusicVideos::AssetZip.fetcher = @previous_fetcher
  end

  # The session cookie of an admin, logged in through the server itself.
  def admin_cookie
    token = Studio::Link.create_magic_link(email: users(:alex).email).token
    http = Net::HTTP.new("127.0.0.1", @port)
    http.read_timeout = 30
    response = http.post(link_consume_path(token:), "", "Host" => "www.example.com")
    response.get_fields("set-cookie").map { |c| c.split(";").first }.join("; ")
  end

  def wait_until(seconds = 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    true
  end

  test "a client that goes away mid-download stops the zip at once, logs nothing, and frees the thread" do
    cookie = admin_cookie
    files = MusicVideos::AssetZip::Manifest.for(@alt).entries.count { |e| e.kind != :text }
    assert_operator files, :>, 2, "the seed must have several files to fetch, or stopping proves nothing"
    errors_before = ErrorLog.count

    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write("GET #{music_video_alt_video_download_path(@video, @alt)} HTTP/1.1\r\n" \
                 "Host: www.example.com\r\nCookie: #{cookie}\r\nConnection: close\r\n\r\n")
    head = +""
    head << socket.readpartial(16_384) until head.include?("\r\n\r\n")
    assert_match(%r{\AHTTP/1.1 200}, head)
    # A reset, not a polite FIN: the next write from Puma fails at once.
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    socket.close
    @gate << :closed

    assert wait_until { @server.pool_capacity == 1 }, "the Puma thread is still busy after the client went away"
    assert_kind_of Puma::ConnectionError, @fetcher.raised, "a closed client surfaces in the sink as Puma::ConnectionError"
    assert_equal 1, @fetcher.started.size,
                 "fetched #{@fetcher.started.size} of #{files} files after the client went away: #{@fetcher.started.inspect}"
    assert_equal errors_before, ErrorLog.count, "a disconnect is not an error"
  end
end
