require "test_helper"

# [unit] Content::AttachVideo — what the upload on a video_post_x card accepts,
# and that a refusal stores nothing.
class Content::AttachVideoTest < ActiveSupport::TestCase
  Upload = Struct.new(:original_filename, :content_type, :size, :body) do
    def tempfile = (@tempfile ||= StringIO.new(body))
    def read = raise("read the IO, not a string: a 100 MB upload must not be loaded into memory")
  end

  setup do
    @content = Content.create!(title: "Panthers win", workflow: "video_post_x")
    @stored  = []
  end

  def attach(upload)
    Content::AttachVideo.stub(:store, ->(key:, body:) { @stored << [key, body.read]; "https://cdn.test/#{key}" }) do
      Content::AttachVideo.new(@content, upload).call
    end
  end

  test "stores the MP4 under the card's slug and records its URL" do
    attach(Upload.new("win.MP4", "video/mp4", 5, "bytes"))

    assert_equal [["video_posts/#{@content.slug}.mp4", "bytes"]], @stored
    assert_equal "https://cdn.test/video_posts/#{@content.slug}.mp4", @content.reload.final_video_url
  end

  test "refuses a missing file, a non-MP4 and an oversize MP4 without storing" do
    {
      nil                                                                         => "Attach the MP4",
      Upload.new("win.mov", "video/quicktime", 5, "b")                            => "not an MP4",
      Upload.new("win.mp4", "text/plain", 5, "b")                                 => "not an MP4",
      Upload.new("win.mp4", "video/mp4", Content::AttachVideo::MAX_BYTES + 1, "b") => "over 100 MB"
    }.each do |upload, message|
      error = assert_raises(Content::AttachVideo::Refused) { attach(upload) }
      assert_includes error.message, message
    end

    assert_empty @stored
    assert_nil @content.reload.final_video_url
  end

  test "refuses when storage returns no public URL" do
    Content::AttachVideo.stub(:store, ->(**) { nil }) do
      error = assert_raises(Content::AttachVideo::Refused) do
        Content::AttachVideo.new(@content, Upload.new("win.mp4", "video/mp4", 5, "b")).call
      end
      assert_includes error.message, "no public URL"
    end
  end
end
