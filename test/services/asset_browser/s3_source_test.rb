# frozen_string_literal: true

require "test_helper"
require "aws-sdk-s3"
require "open3"

# [unit] AssetBrowser::S3Source against a stubbed Aws client: it asks
# ListObjectsV2 for one page with the delimiter and token, and maps the answer
# back to logical keys through Studio::S3's own key namespace.
class AssetBrowserS3SourceTest < ActiveSupport::TestCase
  setup do
    @client = Aws::S3::Client.new(stub_responses: true, region: "us-east-2")
    @source = AssetBrowser::S3Source.new(client: @client, bucket: "mcritchie-studio-dev")
  end

  test "list sends prefix, delimiter, page size and token, and reads one page" do
    @client.stub_responses(:list_objects_v2, {
      common_prefixes: [ { prefix: "music_videos/drake/" } ],
      contents: [ { key: "music_videos/cover.jpg", size: 10, last_modified: Time.utc(2026, 9, 1) } ],
      is_truncated: true, next_continuation_token: "tok-2"
    })

    page = @source.list(prefix: "music_videos/", token: "tok-1", max: 50, delimiter: "/")

    params = @client.api_requests.last[:params]
    assert_equal({ bucket: "mcritchie-studio-dev", prefix: "music_videos/", delimiter: "/", max_keys: 50, continuation_token: "tok-1" }, params)
    assert_equal %w[music_videos/drake/], page.folders
    assert_equal %w[music_videos/cover.jpg], page.files.map(&:key)
    assert_equal "tok-2", page.next_token
  end

  test "an untruncated page has no next token, and the folder marker is not a file" do
    @client.stub_responses(:list_objects_v2, {
      contents: [ { key: "artists/", size: 0, last_modified: Time.utc(2026, 9, 1) } ], is_truncated: false
    })

    page = @source.list(prefix: "artists/", max: 50, delimiter: "/")

    assert_empty page.files
    assert_nil page.next_token
  end

  test "keys come back logical when the app lives under a key prefix" do
    Studio.stub(:s3_key_prefix, "hub") do
      @client.stub_responses(:list_objects_v2, {
        common_prefixes: [ { prefix: "hub/artists/" } ],
        contents: [ { key: "hub/readme.txt", size: 1, last_modified: Time.utc(2026, 9, 1) } ]
      })

      page = @source.list(prefix: "", max: 10, delimiter: "/")

      assert_equal "hub/", @client.api_requests.last[:params][:prefix]
      assert_equal %w[artists/], page.folders
      assert_equal %w[readme.txt], page.files.map(&:key)
    end
  end

  test "head reads size, type and time, and a missing key is nil" do
    @client.stub_responses(:head_object, [
      { content_length: 42, content_type: "video/mp4", last_modified: Time.utc(2026, 9, 2) },
      "NotFound"
    ])

    entry = @source.head(key: "clip.mp4")
    assert_equal [ 42, "video/mp4" ], [ entry.size, entry.content_type ]
    assert_nil @source.head(key: "gone.mp4")
  end

  test "a storage failure surfaces as Unavailable with no detail beyond its class" do
    @client.stub_responses(:list_objects_v2, "AccessDenied")

    error = assert_raises(AssetBrowser::Unavailable) { @source.list(prefix: "", max: 10, delimiter: "/") }
    assert_match(/AccessDenied/, error.message)
  end

  test "signed_url presigns a GET for the full key that expires" do
    url = @source.signed_url(key: "artists/drake/portrait_01.jpg", expires_in: 900)

    assert_match %r{mcritchie-studio-dev.*artists/drake/portrait_01\.jpg}, url
    assert_includes url, "X-Amz-Expires=900"
    assert_not_includes url, "response-content-disposition"
  end

  test "signed_url with download_as answers as an attachment under that name" do
    url = @source.signed_url(key: "music_videos/a/b/chunks/b_chunk_01_0000_0025.mp4", expires_in: 900,
                             download_as: "b_chunk_01_0000_0025.mp4")

    disposition = CGI.unescape(url[/response-content-disposition=([^&]+)/, 1])
    assert_match(/\Aattachment; filename="b_chunk_01_0000_0025\.mp4"/, disposition)
    assert_includes url, "X-Amz-Signature"
  end
end

# [unit] Regression (music-video-cast-panel): the cast panel signs a still before
# anything has listed or headed, so signed_url must load aws-sdk-s3 itself, and a
# missing credential must read as Unavailable. This file requires the gem, so the
# check runs in a fresh process where it is not loaded.
class AssetBrowserS3SourceColdSignTest < ActiveSupport::TestCase
  test "signed_url works in a process where aws-sdk-s3 is not loaded yet" do
    script = <<~RUBY
      print(defined?(Aws::S3::Presigner) ? "preloaded" : "cold", " ")
      begin
        url = AssetBrowser::S3Source.new(bucket: "mcritchie-studio-dev").signed_url(key: "a/b.jpg", expires_in: 60)
        print(url.include?("X-Amz-Signature") ? "signed" : "unsigned")
      rescue AssetBrowser::Unavailable
        print "unavailable"
      end
    RUBY
    # No credentials anywhere, as on CI: signing must degrade to Unavailable, not raise.
    env = { "RAILS_ENV" => "test", "AWS_ACCESS_KEY_ID" => "", "AWS_SECRET_ACCESS_KEY" => "",
            "AWS_EC2_METADATA_DISABLED" => "true", "AWS_PROFILE" => "no-such-profile" }
    out, status = Open3.capture2e(env, "bin/rails", "runner", script, chdir: Rails.root.to_s)

    assert status.success?, out
    assert out.strip.end_with?("cold unavailable"), out
  end
end
