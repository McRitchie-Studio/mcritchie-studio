require "test_helper"
require "socket"
require "puma/client"

# [unit] The asset zip's streaming half (piece 17): the Writer stores each
# entry as it is read, rolls a file that fails part way out of the archive and
# lists it in the README (written last), never failing the zip; the Fetcher
# reads R2 as a stream, maps storage errors to a reason, and fetches sheet
# images only from https public hosts, redirects included. No network.
class MusicVideosAssetZipWriterTest < ActiveSupport::TestCase
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
    zip = ZipKit::Streamer.new(ZipKit::NullWriter)
    writer = MusicVideos::AssetZip::Writer.new(FakeManifest.new([entry("a"), entry("gone"), entry("later"), entry("prompt", kind: :text),
                                                                 entry("later-sheet", kind: :url)], []),
                                               fetcher:, logger: Logger.new(log))
    assert_no_difference -> { ErrorLog.count } do
      assert_raises(Puma::ConnectionError) { writer.write(zip) }
    end
    assert_equal %w[a gone], fetcher.started, "nothing is fetched after the client has gone"
    assert_not_includes zip.instance_variable_get(:@files).map(&:filename), "v_alt_1/README.txt"
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

  test "a sheet URL off an https public host is refused before any request" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    with_http(->(*) { flunk "no request may be made" }) do
      %w[http://assets.mcritchie.studio/s.png https://127.0.0.1/s.png https://localhost/s.png data:image/png;base64,AA].each do |url|
        error = assert_raises(FetchFailed, url) { fetcher.each_chunk(Entry.new(path: "s", kind: :url, source: url, label: "s")) { flunk } }
        assert_equal "not an https public host", error.message
      end
    end
  end

  test "a sheet streams over https; a redirect is followed only to another public https host" do
    fetcher = MusicVideos::AssetZip::Fetcher.new
    hosts = []
    responses = {
      "assets.mcritchie.studio" => redirect("https://cdn.example.com/s.png"),
      "cdn.example.com" => ok(%w[png- bytes]),
      "evil.example.com" => redirect("https://169.254.169.254/latest/meta-data"),
      "gone.example.com" => Net::HTTPNotFound.new("1.1", "404", "Not Found")
    }
    with_http(->(host) { hosts << host; responses.fetch(host) }) do
      got = +""
      fetcher.each_chunk(Entry.new(path: "s", kind: :url, source: "https://assets.mcritchie.studio/s.png", label: "s")) { |b| got << b }
      assert_equal "png-bytes", got
      assert_equal %w[assets.mcritchie.studio cdn.example.com], hosts

      error = assert_raises(FetchFailed) { fetcher.each_chunk(Entry.new(path: "s", kind: :url, source: "https://evil.example.com/s.png", label: "s")) { flunk } }
      assert_equal "not an https public host", error.message
      error = assert_raises(FetchFailed) { fetcher.each_chunk(Entry.new(path: "s", kind: :url, source: "https://gone.example.com/s.png", label: "s")) { flunk } }
      assert_equal "the host answered HTTP 404", error.message
    end
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

  # Net::HTTP.start answers with the response the block picks for the host.
  def with_http(pick)
    http = Class.new do
      define_method(:initialize) { |response| @response = response }
      define_method(:request) { |_req, &blk| blk.call(@response) }
    end
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |host, *_args, **_opts, &blk| blk.call(http.new(pick.call(host))) }
    yield
  ensure
    Net::HTTP.singleton_class.send(:remove_method, :start)
    Net::HTTP.define_singleton_method(:start, original) unless Net::HTTP.respond_to?(:start)
  end
end
