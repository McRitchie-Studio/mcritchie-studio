require "test_helper"
require_relative "../../support/pinned_fetch_world"
require "socket"
require "puma/client"

# [unit] The asset zip's streaming half (piece 17): the Writer stores each
# entry as it is read, rolls a file that fails part way out of the archive and
# lists it in the README (written last), never failing the zip; the Fetcher
# reads R2 as a stream, maps storage errors to a reason, and fetches sheet
# images only from https public hosts, redirects included, each over a
# connection to the address its host was vetted against. No network, no DNS.
class MusicVideosAssetZipWriterTest < ActiveSupport::TestCase
  include PinnedFetchWorld

  Manifest = MusicVideos::AssetZip::Manifest
  Entry = Manifest::Entry
  FetchFailed = MusicVideos::AssetZip::FetchFailed

  # A manifest stand-in: the Writer reads entries, missing, readme_path, readme.
  FakeManifest = Struct.new(:entries, :missing) do
    def readme_path = "v_alt_1/README.txt"

    def filename = "v_alt_1.zip"

    def alt_video = nil

    def readme(also = []) = "README\n#{(missing + also).map { |m| "#{m.path}: #{m.reason}" }.join("\n")}\n"
  end

  # Yields a megabyte in 64 KB pieces, or fails after the first piece.
  class ChunkedFetcher
    attr_reader :peak

    def initialize = @peak = 0

    def each_chunk(entry)
      piece = "x".b * 65_536
      16.times do |i|
        raise FetchFailed, "storage read failed (NetworkingError)" if entry.source == "breaks" && i == 1
        raise ArgumentError, "surprise" if entry.source == "surprise"

        @peak = [@peak, piece.bytesize].max
        yield piece
      end
    end
  end

  def write(entries, missing: [], fetcher: ChunkedFetcher.new)
    io = StringIO.new("".b)
    result = nil
    ZipKit::Streamer.open(io) { |zip| result = MusicVideos::AssetZip::Writer.new(FakeManifest.new(entries, missing), fetcher:, logger: nil).write(zip) }
    io.rewind
    [ZipKit::FileReader.read_zip_structure(io: io), io, result]
  end

  def body(io, entry)
    out = +""
    reader = entry.extractor_from(io)
    out << reader.extract until reader.eof?
    out
  end

  test "every entry is stored uncompressed, in manifest order, with the README last" do
    entries, io, result = write([Entry.new(path: "v_alt_1/clip_01_0000-0025/source_clip.mp4", kind: :object, source: "a", label: "Clip 1 source clip"),
                                 Entry.new(path: "v_alt_1/clip_01_0000-0025/prompt.txt", kind: :text, source: "Replace the man.", label: "Clip 1 prompt")])
    assert_equal %w[v_alt_1/clip_01_0000-0025/source_clip.mp4 v_alt_1/clip_01_0000-0025/prompt.txt v_alt_1/README.txt], entries.map(&:filename)
    assert(entries.all? { |e| e.storage_mode.zero? }, "store-only")
    assert_equal 16 * 65_536, entries.first.uncompressed_size
    assert_equal "Replace the man.", body(io, entries[1])
    assert_equal 3, result.written
    assert_empty result.missing
  end

  test "a file that fails part way is rolled out of the archive and listed in the README" do
    entries, io, result = write([Entry.new(path: "v_alt_1/c/frames/frame_1_B_0045.jpg", kind: :object, source: "breaks", label: "Frame 1 (B)"),
                                 Entry.new(path: "v_alt_1/c/sheets/sheet_1_B_04_x.png", kind: :url, source: "surprise", label: "Sheet 1"),
                                 Entry.new(path: "v_alt_1/c/source_clip.mp4", kind: :object, source: "fine", label: "Clip source")],
                                missing: [Manifest::Missing.new(path: "v_alt_1/d/", label: "Clip 4", reason: "re-tiled")])
    assert_equal %w[v_alt_1/c/source_clip.mp4 v_alt_1/README.txt], entries.map(&:filename), "the archive stays valid"
    readme = body(io, entries.last)
    assert_includes readme, "v_alt_1/c/frames/frame_1_B_0045.jpg: storage read failed (NetworkingError)"
    assert_includes readme, "v_alt_1/c/sheets/sheet_1_B_04_x.png: could not be read (ArgumentError)"
    assert_includes readme, "v_alt_1/d/: re-tiled"
    assert_equal 3, result.missing.size
  end

  test "the writer holds one network piece at a time, never a file whole" do
    fetcher = ChunkedFetcher.new
    sink = ZipKit::NullWriter
    MusicVideos::AssetZip::Writer.new(FakeManifest.new([Entry.new(path: "a.mp4", kind: :object, source: "a", label: "a")], []),
                                      fetcher:, logger: nil).write(ZipKit::Streamer.new(sink))
    assert_equal 65_536, fetcher.peak
  end

  # --- Disconnects and ErrorLog (piece 20) -------------------------------

  # Records every entry it starts. On "gone" it raises what Puma raises into
  # the body's sink once the browser has gone away (proved over a real socket
  # in test/integration/asset_zip_client_disconnect_test.rb); on "surprise"
  # an error nobody named.
  class RecordingFetcher
    attr_reader :started

    def initialize = @started = []

    def each_chunk(entry)
      @started << entry.source
      yield "x".b * 100
      raise Puma::ConnectionError, "Socket timeout writing data" if entry.source == "gone"
      raise ArgumentError, "surprise #{entry.source}" if entry.source.start_with?("surprise")
      raise FetchFailed, "not in storage" if entry.source == "absent"

      yield "y".b * 100
    end
  end

  def entry(source, kind: :object) = Entry.new(path: "v_alt_1/c/#{source}.bin", kind:, source:, label: source)

  test "a client that goes away stops the zip at once: no further fetch, no README, nothing in ErrorLog" do
    fetcher = RecordingFetcher.new
    log = StringIO.new
    out = StringIO.new("".b)
    zip = ZipKit::Streamer.new(out)
    writer = MusicVideos::AssetZip::Writer.new(FakeManifest.new([entry("a"), entry("gone"), entry("later"), entry("prompt", kind: :text),
                                                                 entry("later-sheet", kind: :url)], []),
                                               fetcher:, logger: Logger.new(log))
    assert_no_difference -> { ErrorLog.count } do
      assert_raises(Puma::ConnectionError) { writer.write(zip) }
    end
    assert_equal %w[a gone], fetcher.started, "nothing is fetched after the client has gone"
    assert_not_includes out.string, "README.txt", "nothing more is written after the client has gone"
    assert_no_match(/WARN|ERROR/, log.string, "a disconnect is not an error")
    assert_match(/client went away after 1 of 5 files/, log.string)
  end

  test "failures other than a disconnect are recorded in ErrorLog once per download, and the zip still finishes" do
    fetcher = RecordingFetcher.new
    entries, io, result = nil
    assert_difference -> { ErrorLog.count }, 1 do
      entries, io, result = write([entry("surprise-1"), entry("absent"), entry("surprise-2"), entry("fine")], fetcher:)
    end
    assert_equal %w[surprise-1 absent surprise-2 fine], fetcher.started
    assert_equal %w[v_alt_1/c/fine.bin v_alt_1/README.txt], entries.map(&:filename)
    readme = body(io, entries.last)
    assert_includes readme, "v_alt_1/c/surprise-1.bin: could not be read (ArgumentError)"
    assert_includes readme, "v_alt_1/c/surprise-2.bin: could not be read (ArgumentError)"
    assert_includes readme, "v_alt_1/c/absent.bin: not in storage"
    assert_equal 3, result.missing.size
    error = ErrorLog.order(:id).last
    assert_equal "surprise surprise-1", error.message
    assert_equal "v_alt_1.zip", error.target_name
  end

  test "a named fetch failure is a README line, not an ErrorLog row" do
    assert_no_difference -> { ErrorLog.count } do
      write([entry("absent"), entry("fine")], fetcher: RecordingFetcher.new)
    end
  end

  # A Streamer whose README write fails: an error that ends the stream itself.
  class BrokenReadmeZip < SimpleDelegator
    def write_stored_file(path, &)
      raise IOError, "the zip could not be finished" if path.end_with?("README.txt")

      __getobj__.write_stored_file(path, &)
    end
  end

  test "an error that ends the stream is recorded once, with any per-file failure, and still raised" do
    zip = BrokenReadmeZip.new(ZipKit::Streamer.new(ZipKit::NullWriter))
    writer = MusicVideos::AssetZip::Writer.new(FakeManifest.new([entry("fine")], []), fetcher: RecordingFetcher.new, logger: nil)
    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(IOError) { writer.write(zip) }
    end
    assert_equal "the zip could not be finished", ErrorLog.order(:id).last.message

    zip = BrokenReadmeZip.new(ZipKit::Streamer.new(ZipKit::NullWriter))
    writer = MusicVideos::AssetZip::Writer.new(FakeManifest.new([entry("surprise-1")], []), fetcher: RecordingFetcher.new, logger: nil)
    assert_difference -> { ErrorLog.count }, 1, "once per download, not once per failure" do
      assert_raises(IOError) { writer.write(zip) }
    end
  end

  # --- Fetcher -----------------------------------------------------------

  def r2_fetcher(client) = MusicVideos::AssetZip::Fetcher.new(client:, bucket: "test-bucket")

  def stub_client(**responses)
    require "aws-sdk-s3"
    Aws::S3::Client.new(stub_responses: responses, region: "auto", credentials: Aws::Credentials.new("a", "b"))
  end

  test "an R2 object streams to the block; a missing one is a reason, not a crash" do
    got = +""
    r2_fetcher(stub_client(get_object: { body: "chunk bytes" })).each_chunk(Entry.new(path: "x", kind: :object, source: "k.mp4", label: "x")) { |b| got << b }
    assert_equal "chunk bytes", got

    error = assert_raises(FetchFailed) do
      r2_fetcher(stub_client(get_object: "NoSuchKey")).each_chunk(Entry.new(path: "x", kind: :object, source: "k.mp4", label: "x")) { flunk }
    end
    assert_equal "not in storage", error.message
    error = assert_raises(FetchFailed) do
      r2_fetcher(stub_client(get_object: "AccessDenied")).each_chunk(Entry.new(path: "x", kind: :object, source: "k.mp4", label: "x")) { flunk }
    end
    assert_equal "storage read failed (AccessDenied)", error.message
  end

  # A real HTTP socket stands in for R2 (stub_responses skips the transport),
  # so this shows what Seahorse does with an error raised from the read's
  # block: it finishes the session (the socket closes) and signals the error
  # as not retryable, so it reaches the Writer as itself, not as a reason.
  test "a disconnect inside an R2 read closes the read and is neither retried nor turned into a reason" do
    server = TCPServer.new("127.0.0.1", 0)
    requests = Thread::Queue.new
    closed = Thread::Queue.new
    thread = Thread.new do
      loop do
        conn = server.accept
        requests << :request
        head = +""
        head << conn.readpartial(4096) until head.include?("\r\n\r\n")
        conn.write("HTTP/1.1 200 OK\r\nContent-Length: 104857600\r\nContent-Type: application/octet-stream\r\n\r\n")
        begin
          loop { conn.write("z" * 65_536) }
        rescue SystemCallError, IOError
          closed << :closed
        ensure
          conn.close
        end
      end
    rescue IOError
      nil
    end
    require "aws-sdk-s3"
    client = Aws::S3::Client.new(endpoint: "http://127.0.0.1:#{server.addr[1]}", force_path_style: true, region: "auto",
                                 credentials: Aws::Credentials.new("a", "b"))
    assert_raises(Puma::ConnectionError) do
      r2_fetcher(client).each_chunk(entry("k")) { raise Puma::ConnectionError, "Socket timeout writing data" }
    end
    assert_equal :closed, closed.pop(timeout: 10), "the R2 read is closed"
    assert_equal 1, requests.size, "a disconnect is not retried"
  ensure
    server&.close
    thread&.kill
  end

  SHEET = "https://assets.mcritchie.studio/s.png"

  def sheet(url = SHEET) = Entry.new(path: "v_alt_1/c/sheets/s.png", kind: :url, source: url, label: "Sheet 1")

  def sheet_bytes(fetcher, url = SHEET)
    got = +""
    fetcher.each_chunk(sheet(url)) { |b| got << b }
    got
  end

  test "a sheet URL off an https public host is refused before any connection" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    with_http(->(*) { flunk "no connection may be made" }) do
      %w[http://assets.mcritchie.studio/s.png https://127.0.0.1/s.png https://localhost/s.png https://127.1/s.png
         data:image/png;base64,AA].each do |url|
        error = assert_raises(FetchFailed, url) { fetcher.each_chunk(sheet(url)) { flunk } }
        assert_equal "not an https public host", error.message
      end
    end
  end

  test "a sheet whose host could not be looked up is refused with its own reason, before any connection" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    with_http(->(*) { flunk "no connection may be made" }) do
      with_resolver("dead.example.com" => :fail) do
        error = assert_raises(FetchFailed) { fetcher.each_chunk(sheet("https://dead.example.com/s.png")) { flunk } }
        assert_equal "the host could not be looked up just now", error.message
      end
    end
  end

  test "[unit] asset zip fetcher refuses a disguised internal host" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    pins = []
    with_http(->(host, address) { pins << [host, address]; ok(%w[png- bytes]) }) do
      { "all internal" => ["10.0.0.7"], "one internal among public" => [PUBLIC, "169.254.169.254"],
        "loopback, IPv4-mapped" => ["::ffff:127.0.0.1"] }.each do |what, addresses|
        with_resolver("assets.mcritchie.studio" => addresses) do
          error = assert_raises(FetchFailed, what) { fetcher.each_chunk(sheet) { flunk } }
          assert_equal "not an https public host", error.message
        end
      end
      assert_empty pins, "a refused host is never connected to"

      # THE CONTROL: the same URL, a public answer.
      with_resolver("assets.mcritchie.studio" => [PUBLIC]) { assert_equal "png-bytes", sheet_bytes(fetcher) }
      assert_equal [["assets.mcritchie.studio", PUBLIC]], pins
    end
  end

  test "a sheet streams over https; a redirect is followed only to another public https host, each at its vetted address" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    pins = []
    cdn = "151.101.1.69"
    responses = {
      "assets.mcritchie.studio" => redirect("https://cdn.example.com/s.png"),
      "cdn.example.com" => ok(%w[png- bytes]),
      "evil.example.com" => redirect("https://169.254.169.254/latest/meta-data"),
      "inward.example.com" => redirect("https://meta.example.com/latest/meta-data"),
      "plain.example.com" => redirect("http://cdn.example.com/s.png"),
      "gone.example.com" => Net::HTTPNotFound.new("1.1", "404", "Not Found")
    }
    answers = responses.keys.index_with { [PUBLIC] }.merge("cdn.example.com" => [cdn], "meta.example.com" => ["169.254.169.254"])
    with_http(->(host, address) { pins << [host, address]; responses.fetch(host) }) do
      with_resolver(answers) do |lookups|
        assert_equal "png-bytes", sheet_bytes(fetcher)
        assert_equal [["assets.mcritchie.studio", PUBLIC], ["cdn.example.com", cdn]], pins
        assert_equal %w[assets.mcritchie.studio cdn.example.com], lookups, "one lookup a hop"

        %w[evil inward plain].each do |name|
          pins.clear
          error = assert_raises(FetchFailed, name) { fetcher.each_chunk(sheet("https://#{name}.example.com/s.png")) { flunk } }
          assert_equal "not an https public host", error.message
          assert_equal [["#{name}.example.com", PUBLIC]], pins, "the redirect's target is never connected to"
        end
        error = assert_raises(FetchFailed) { fetcher.each_chunk(sheet("https://gone.example.com/s.png")) { flunk } }
        assert_equal "the host answered HTTP 404", error.message
      end
    end
  end

  test "a redirect chain longer than the cap is a reason" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    hops = 0
    with_http(->(*) { hops += 1; redirect("https://assets.mcritchie.studio/s.png?#{hops}") }) do
      with_resolver("assets.mcritchie.studio" => [PUBLIC]) do
        error = assert_raises(FetchFailed) { fetcher.each_chunk(sheet) { flunk } }
        assert_equal "more than 3 redirects", error.message
        assert_equal 4, hops
      end
    end
  end

  # A REBIND, over the engine's REAL client: only the socket is the test's
  # (PinnedFetchWorld#with_dials refuses it and records what was asked for).
  # The name answers a public address when it is vetted and the loopback when
  # asked again; the connection must go to the first, without asking again.
  test "[unit] a sheet host that answers differently a second time is still connected to at the vetted address" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    rebinding = ->(asked) { asked == 1 ? [PUBLIC] : ["127.0.0.1"] }
    with_resolver("assets.mcritchie.studio" => rebinding) do |lookups|
      with_dials do |dials|
        error = assert_raises(FetchFailed) { fetcher.each_chunk(sheet) { flunk } }
        assert_equal "the host could not be read (ECONNREFUSED)", error.message, "the test's socket refuses every connection"
        assert_equal [PUBLIC], dials, "the connection is to the vetted address, not to the name"
        assert_equal 1, lookups.size, "one lookup: the connection does not resolve the name again"

        # THE CONTROL: this resolver does answer the loopback the second time,
        # and a fetch that meets that answer is refused without connecting.
        error = assert_raises(FetchFailed) { fetcher.each_chunk(sheet) { flunk } }
        assert_equal "not an https public host", error.message
        assert_equal [PUBLIC], dials
      end
    end
  end

  test "an address that cannot be reached falls through to the next vetted one, and to no other" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    with_resolver("assets.mcritchie.studio" => [PUBLIC_V6, PUBLIC]) do
      with_dials do |dials|
        assert_raises(FetchFailed) { fetcher.each_chunk(sheet) { flunk } }
        assert_equal [PUBLIC, PUBLIC_V6], dials, "IPv4 first, then the rest, then stop"
      end

      pins = []
      unreachable = lambda do |_host, address|
        pins << address
        address == PUBLIC ? raise(Errno::EHOSTUNREACH) : ok(%w[png- bytes])
      end
      with_http(unreachable) { assert_equal "png-bytes", sheet_bytes(fetcher) }
      assert_equal [PUBLIC, PUBLIC_V6], pins
    end
  end

  test "the connection is closed when the sheet is read, and when the reader goes away mid-body" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    with_resolver("assets.mcritchie.studio" => [PUBLIC]) do
      opened = with_http(->(*) { ok(%w[png- bytes]) }) do |connections|
        sheet_bytes(fetcher)
        assert_raises(Puma::ConnectionError) { fetcher.each_chunk(sheet) { raise Puma::ConnectionError, "Socket timeout writing data" } }
        connections
      end
      assert_equal 2, opened.size
      assert(opened.none?(&:started?), "every connection is finished")
      assert_equal [[5, 20]] * 2, opened.map { |http| [http.open_timeout, http.read_timeout] }, "the fetcher's own timeouts"
    end
  end

  # The Writer over the real Fetcher: a refused or unresolved sheet is a line
  # in the README like any other failed read, and the zip still finishes.
  test "a refused and an unresolved sheet are README lines, and the rest of the zip is written" do
    entries = [Entry.new(path: "v_alt_1/c/sheets/inside.png", kind: :url, source: "https://intranet.example.com/s.png", label: "Sheet 1"),
               Entry.new(path: "v_alt_1/c/sheets/dead.png", kind: :url, source: "https://dead.example.com/s.png", label: "Sheet 2"),
               Entry.new(path: "v_alt_1/c/sheets/fine.png", kind: :url, source: SHEET, label: "Sheet 3")]
    files, io, result = nil
    with_http(->(*) { ok(%w[png- bytes]) }) do
      with_resolver("intranet.example.com" => ["192.168.1.10"], "dead.example.com" => :fail, "assets.mcritchie.studio" => [PUBLIC]) do
        assert_no_difference -> { ErrorLog.count } do
          files, io, result = write(entries, fetcher: MusicVideos::AssetZip::Fetcher.new)
        end
      end
    end
    assert_equal %w[v_alt_1/c/sheets/fine.png v_alt_1/README.txt], files.map(&:filename)
    assert_equal "png-bytes", body(io, files.first)
    readme = body(io, files.last)
    assert_includes readme, "v_alt_1/c/sheets/inside.png: not an https public host"
    assert_includes readme, "v_alt_1/c/sheets/dead.png: the host could not be looked up just now"
    assert_equal 2, result.missing.size
  end

  private

  def ok(pieces)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) { |&blk| pieces.each(&blk) }
    response
  end

  def redirect(location)
    response = Net::HTTPFound.new("1.1", "302", "Found")
    response["location"] = location
    response
  end

  # The engine's pinned client, replaced: `pick` is called with the host and
  # the address the connection was pinned to (nil when nothing was resolved)
  # as it opens, and answers the response, or raises as a connection would.
  # Yields every connection made.
  class PinnedHttp
    attr_accessor :open_timeout, :read_timeout

    def initialize(pick, host, address)
      @pick = pick
      @host = host
      @address = address
      @started = false
    end

    def start
      @response = @pick.call(@host, @address)
      @started = true
      self
    end

    def started? = @started

    def finish = @started = false

    def request(_request, &blk) = blk.call(@response)
  end

  def with_http(pick)
    connections = []
    pinned = ->(uri, address) { PinnedHttp.new(pick, uri.host, address).tap { |http| connections << http } }
    Studio::ImageCache.stub(:pinned_http, pinned) { yield connections }
  end
end
