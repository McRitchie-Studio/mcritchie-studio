require "test_helper"

# [unit] Tiktok::InboxUpload — TikTok's FILE_UPLOAD into the inbox, with the
# HTTP faked. Pins the chunk rules (one chunk under the chunk size, otherwise
# 10 MB chunks with the remainder in the last, counted by rounding DOWN), the
# init payload (no caption: the inbox endpoint takes only the source), the
# Content-Range of every PUT, and that a TikTok refusal names its step.
class Tiktok::InboxUploadTest < ActiveSupport::TestCase
  MB = Tiktok::InboxUpload::MB
  Upload = Tiktok::InboxUpload

  # Answers init with an upload URL, every PUT with `put_code`, status with `status`.
  class FakeHttp
    attr_reader :calls

    def initialize(init: nil, put_code: 206, status: "SEND_TO_USER_INBOX")
      @init = init || { "data" => { "publish_id" => "v_inbox_file~synthetic.1", "upload_url" => "https://upload.invalid/u?x=1" },
                        "error" => { "code" => "ok" } }
      @put_code = put_code
      @status = status
      @calls = []
    end

    def call(verb, url, headers, body)
      @calls << { verb:, url:, headers:, body: }
      return [@put_code, ""] if verb == :put
      return [200, JSON.generate(@init)] if url == Upload::INIT_URL

      [200, JSON.generate({ "data" => { "status" => @status }, "error" => { "code" => "ok" } })]
    end
  end

  def upload(http) = Upload.new(http:, token: -> { "synthetic-token" })

  def reader(bytes) = ->(offset, length) { bytes.byteslice(offset, length) }

  test "a file of the chunk size or less goes as one chunk" do
    [1, 3 * MB, 10 * MB].each do |size|
      plan = Upload.plan(size)
      assert_equal [size, 1], [plan.chunk_size, plan.count], "#{size} bytes"
      assert_equal [[0, size - 1]], plan.ranges
    end
  end

  test "a larger file goes in 10 MB chunks, the last carrying the remainder" do
    plan = Upload.plan(25 * MB + 7)

    assert_equal [10 * MB, 2], [plan.chunk_size, plan.count], "25 MB / 10 MB rounds down to 2"
    assert_equal [[0, 10 * MB - 1], [10 * MB, 25 * MB + 6]], plan.ranges
    assert_operator plan.ranges.last.then { |a, b| b - a + 1 }, :<=, Upload::MAX_FINAL_CHUNK
  end

  test "every plan keeps TikTok's chunk rules" do
    [5 * MB, 10 * MB + 1, 19 * MB, 20 * MB, 63 * MB, 200 * MB, Upload::MAX_BYTES].each do |size|
      plan = Upload.plan(size)
      sizes = plan.ranges.map { |a, b| b - a + 1 }

      assert_equal size, sizes.sum, "#{size}: every byte once"
      assert_equal size / plan.chunk_size, plan.count, "#{size}: the count rounds down" unless plan.count == 1
      assert_operator plan.count, :<=, Upload::MAX_CHUNKS
      sizes[0...-1].each { |s| assert_includes Upload::MIN_CHUNK..Upload::MAX_CHUNK, s }
      assert_operator sizes.last, :<=, Upload::MAX_FINAL_CHUNK
    end
  end

  test "an empty or oversized file is refused before anything is sent" do
    assert_raises(Upload::Error) { Upload.plan(0) }
    assert_raises(Upload::Error) { Upload.plan(Upload::MAX_BYTES + 1) }
  end

  test "init asks for FILE_UPLOAD into the inbox with no caption, then PUTs each chunk in order" do
    bytes = "a" * (10 * MB) + "b" * (12 * MB)
    http = FakeHttp.new
    result = upload(http).call(size: bytes.bytesize, read: reader(bytes))

    init = http.calls.first
    assert_equal Tiktok::PostMedia::INBOX_INIT_URL, init[:url]
    assert_equal "Bearer synthetic-token", init[:headers]["Authorization"]
    assert_equal({ "source_info" => { "source" => "FILE_UPLOAD", "video_size" => 22 * MB, "chunk_size" => 10 * MB,
                                      "total_chunk_count" => 2 } }, JSON.parse(init[:body]))

    puts_ = http.calls.select { |c| c[:verb] == :put }
    assert_equal ["bytes 0-#{10 * MB - 1}/#{22 * MB}", "bytes #{10 * MB}-#{22 * MB - 1}/#{22 * MB}"],
                 puts_.map { |c| c[:headers]["Content-Range"] }
    assert_equal ["video/mp4"], puts_.map { |c| c[:headers]["Content-Type"] }.uniq
    assert_equal [10 * MB, 12 * MB], puts_.map { |c| c[:body].bytesize }
    assert_equal "a", puts_.first[:body][0]
    assert_equal "b", puts_.last[:body][0]
    assert(puts_.all? { |c| c[:url] == "https://upload.invalid/u?x=1" })
    refute(puts_.any? { |c| c[:headers].key?("Authorization") }, "the upload URL carries its own authority")
    assert_equal ["v_inbox_file~synthetic.1", 2], [result[:publish_id], result[:plan].count]
  end

  test "TikTok's refusal at init names the endpoint and TikTok's code" do
    http = FakeHttp.new(init: { "error" => { "code" => "spam_risk_too_many_pending_share", "message" => "too many pending" } })

    error = assert_raises(Upload::Error) { upload(http).call(size: 10, read: reader("x" * 10)) }
    assert_match %r{/v2/post/publish/inbox/video/init/}, error.message
    assert_equal "spam_risk_too_many_pending_share", error.code
    assert(http.calls.none? { |c| c[:verb] == :put })
  end

  test "a refused chunk names which, and reports the publish id it was given first" do
    http = FakeHttp.new(put_code: 400)
    seen = []

    error = assert_raises(Upload::Error) do
      upload(http).call(size: 10, read: reader("x" * 10)) { |_step, id| seen << id }
    end
    assert_match(/chunk 1 of 1 \(HTTP 400\)/, error.message)
    assert_equal ["v_inbox_file~synthetic.1"], seen
  end

  test "a short read is refused rather than sent" do
    error = assert_raises(Upload::Error) { upload(FakeHttp.new).call(size: 10, read: ->(_o, _l) { "x" }) }
    assert_match(/read 1 bytes, expected 10/, error.message)
  end

  test "status reads TikTok's publish status for one publish id" do
    http = FakeHttp.new(status: "PROCESSING_UPLOAD")

    assert_equal "PROCESSING_UPLOAD", upload(http).status("v_inbox_file~synthetic.1")["status"]
    assert_equal Upload::STATUS_URL, http.calls.last[:url]
    assert_equal({ "publish_id" => "v_inbox_file~synthetic.1" }, JSON.parse(http.calls.last[:body]))
  end
end
