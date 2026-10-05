require "test_helper"

# [unit] X::PostMedia against a recording client — the v2 upload sequence.
#
# X sunset the v1.1 upload host on 2025-06-09, and the old code kept "working"
# in every test that never looked at the wire. So these assert the URLs, the
# verbs and the body shapes, which is the whole of what the migration changed.
class X::PostMediaTest < ActiveSupport::TestCase
  class RecordingClient < X::Client
    attr_reader :calls

    def initialize(statuses: [], tweet_failures: [])
      @calls          = []
      @statuses       = statuses
      @tweet_failures = tweet_failures
    end

    def post_json(url, body)
      @calls << [:post_json, url, body]
      return ok("data" => { "id" => "777", "media_key" => "13_777" }) if url.end_with?("/initialize")

      failure = @tweet_failures.shift
      failure ? response(Net::HTTPBadRequest, "400", failure) : ok("data" => { "id" => "999" })
    end

    def post_multipart(url, fields, media_chunk:)
      @calls << [:post_multipart, url, fields, media_chunk.bytesize]
      ok({})
    end

    def post_empty(url)
      @calls << [:post_empty, url]
      ok("data" => { "id" => "777", "processing_info" => { "state" => "pending", "check_after_secs" => 1 } })
    end

    def get(url, params = {})
      @calls << [:get, url, params]
      state = @statuses.shift
      ok("data" => { "id" => "777" }.merge(state ? { "processing_info" => { "state" => state } } : {}))
    end

    private

    def ok(hash) = response(Net::HTTPOK, "200", JSON.generate(hash))

    def response(klass, code, body)
      klass.new("1.1", code, "").tap do |r|
        r.instance_variable_set(:@read, true)
        r.body = body
      end
    end
  end

  CREDS = %w[X_API_KEY X_API_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET].freeze

  setup do
    @prior = CREDS.to_h { |k| [k, ENV[k]] }
    CREDS.each { |k| ENV[k] = "test" }
    @video = Tempfile.new(["clip", ".mp4"]).tap do |f|
      f.binmode
      f.write("x" * (X::PostMedia::CHUNK_SIZE + 10))
      f.flush
    end
  end

  teardown do
    @prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    @video.close!
  end

  def post(client)
    media = X::PostMedia.new(text: "Bills by a mile.", video_path: @video.path, client: client)
    media.define_singleton_method(:pause) { |_seconds| nil }
    media.call
  end

  test "walks initialize, append per chunk, finalize, status, then the post" do
    client = RecordingClient.new(statuses: %w[in_progress succeeded])
    result = post(client)

    assert_equal({ post_id: "999", post_url: "https://x.com/i/web/status/999" }, result)
    assert_equal [
      [:post_json, "https://api.x.com/2/media/upload/initialize",
       { media_type: "video/mp4", total_bytes: X::PostMedia::CHUNK_SIZE + 10, media_category: "tweet_video" }],
      [:post_multipart, "https://api.x.com/2/media/upload/777/append", { "segment_index" => "0" }, X::PostMedia::CHUNK_SIZE],
      [:post_multipart, "https://api.x.com/2/media/upload/777/append", { "segment_index" => "1" }, 10],
      [:post_empty, "https://api.x.com/2/media/upload/777/finalize"],
      [:get, "https://api.x.com/2/media/upload", { "command" => "STATUS", "media_id" => "777" }],
      [:get, "https://api.x.com/2/media/upload", { "command" => "STATUS", "media_id" => "777" }],
      [:post_json, "https://api.x.com/2/tweets", { text: "Bills by a mile.", media: { media_ids: ["777"] } }]
    ], client.calls
  end

  test "never calls the sunset v1.1 upload host" do
    client = RecordingClient.new
    post(client)

    assert_empty client.calls.map { |c| c[1] }.grep(/upload\.twitter\.com|1\.1/)
  end

  test "a status with no processing_info is ready" do
    client = RecordingClient.new(statuses: [])
    post(client)

    assert_equal 1, client.calls.count { |c| c[0] == :get }
  end

  test "failed processing raises and creates no post" do
    client = RecordingClient.new(statuses: %w[failed])

    error = assert_raises(X::PostMedia::Error) { post(client) }
    assert_includes error.message, "media processing failed"
    assert_empty client.calls.select { |c| c[1].end_with?("/2/tweets") }
  end

  test "retries the post once on the media-id propagation lag" do
    client = RecordingClient.new(tweet_failures: ['{"detail":"Your media IDs are invalid."}'])

    assert_equal "999", post(client)[:post_id]
    assert_equal 2, client.calls.count { |c| c[1].end_with?("/2/tweets") }
  end

  test "a second refusal raises with X's own words" do
    client = RecordingClient.new(tweet_failures: ['{"detail":"Your media IDs are invalid."}', '{"detail":"nope"}'])

    assert_includes assert_raises(X::PostMedia::Error) { post(client) }.message, "nope"
  end
end
