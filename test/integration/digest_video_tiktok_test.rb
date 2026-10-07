require "test_helper"
require_relative "../../bin/lib/digest_video"

# [integration] A TikTok digest end to end: bin/digest-video's runner posts
# through the real hub API. yt-dlp, ffprobe and R2 are fakes.
class DigestVideoTiktokIntegrationTest < ActionDispatch::IntegrationTest
  ID = "7400000000000000002".freeze
  PAGE = "https://www.tiktok.com/@testcreator/video/#{ID}".freeze
  KEY = "music_videos/test_creator/tiktok_#{ID}/source/test_creator_tiktok_#{ID}_feat_sample_singer".freeze
  INFO = {
    "id" => ID, "title" => "secretcaption dance (feat. Sample Singer) #secrettag", "description" => "secretcaption",
    "uploader" => "testcreator", "uploader_id" => "6800000000000000002", "channel" => "Test Creator",
    "duration" => 18, "webpage_url" => PAGE, "extractor" => "TikTok", "tags" => ["secrettag"],
    "comments" => [{ "text" => "secretcomment" }], "thumbnail" => "https://p16.tiktokcdn.com/x.jpg?x-signature=ABC",
    "formats" => [{ "url" => "https://v16.tiktokcdn.com/v?signature=ABC" }]
  }.freeze

  Shell = Struct.new(:info) do
    def call(*cmd)
      if File.basename(cmd.first) == "yt-dlp"
        dir = cmd[cmd.index("-P") + 1]
        File.write(File.join(dir, "#{ID}.mp4"), "video")
        File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(info))
        return ["", "", true]
      end
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264" },
                                   { "codec_type" => "audio", "codec_name" => "aac" }],
                     "format" => { "duration" => "18.0" }), "", true]
    end
  end

  class Storage
    attr_reader :puts

    def initialize = @puts = {}

    def put(key, path, _content_type) = @puts[key] = File.read(path)
  end

  # The runner's ApiClient, answered by this app instead of a socket.
  Api = Struct.new(:session) do
    def authenticate = true

    def create(payload)
      token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
      session.post "/api/v1/music_videos", params: { music_video: payload }, as: :json,
                                           headers: { "Authorization" => "Bearer #{token}" }
      JSON.parse(session.response.body).fetch("data")
    end
  end

  setup { Artist.create!(slug: "test-creator", name: "Test Creator", kind: "person") }

  test "a TikTok digest records the creator, keeps the feat. name unresolved, and stores no caption" do
    storage = Storage.new
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: Shell.new(INFO), storage: storage, api: Api.new(self),
                              out: StringIO.new).call(PAGE)
    end
    assert_response :created

    video = MusicVideo.find_by!(platform: "tiktok", source_id: ID)
    assert_equal ["test-creator-tiktok-#{ID}", "TikTok #{ID}", PAGE, "#{KEY}.mp4", 18_000],
                 [video.slug, video.title, video.source_url, video.source_object_key, video.duration_ms]
    assert_equal [%w[test-creator primary]], video.music_video_artists.map { |c| [c.artist_slug, c.role] }
    assert_equal [{ "name" => "Sample Singer", "role" => "featured", "reason" => "no_match" }], video.unresolved_credits

    assert_equal ["#{KEY}.mp4", "#{KEY}.info.json"], storage.puts.keys
    stored = JSON.parse(storage.puts["#{KEY}.info.json"])
    assert_empty stored.keys - DigestVideo::TIKTOK_INFO_ALLOWLIST
    everything = storage.puts.values.join + video.attributes.to_json
    %w[secretcaption secrettag secretcomment signature].each { |bad| refute_includes everything, bad }
  end
end
