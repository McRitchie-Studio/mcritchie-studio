require "test_helper"
require_relative "../../bin/lib/digest_video"

# [integration] An Instagram digest end to end: bin/digest-video's runner posts
# through the real hub API. yt-dlp, ffprobe and R2 are fakes.
class DigestVideoInstagramIntegrationTest < ActionDispatch::IntegrationTest
  ID = "Cxyz-GHI_34".freeze
  PAGE = "https://www.instagram.com/reel/#{ID}/".freeze
  KEY = "music_videos/test_creator/instagram_cxyz_ghi_34/source/test_creator_instagram_cxyz_ghi_34_feat_sample_singer".freeze
  INFO = {
    "_type" => "video", "id" => ID, "title" => "Video by testcreator",
    "description" => "secretcaption dance (feat. Sample Singer) #secrettag", "uploader" => "Test Creator",
    "uploader_id" => "25000002", "channel" => "testcreator", "webpage_url" => "#{PAGE}?igsh=secrettracker",
    "extractor" => "Instagram", "comments" => [{ "text" => "secretcomment" }],
    "thumbnail" => "https://scontent.cdninstagram.com/t.jpg?oe=secretsig",
    "formats" => [{ "url" => "https://scontent.cdninstagram.com/v.mp4?oe=secretsig" }]
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
                     "format" => { "duration" => "19.0" }), "", true]
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
      token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)
      session.post "/api/v1/music_videos", params: { music_video: payload }, as: :json,
                                           headers: { "Authorization" => "Bearer #{token}" }
JSON.parse(session.response.body).fetch("data")
    end
  end

  setup { Artist.create!(slug: "test-creator", name: "Test Creator", kind: "person") }

  test "an emoji-only display name records under the handle" do
    storage = Storage.new
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: Shell.new(INFO.merge("uploader" => "🔥🎤🔥")), storage: storage,
                              api: Api.new(self), out: StringIO.new).call(PAGE)
    end
    assert_response :created

    video = MusicVideo.find_by!(platform: "instagram", source_id: ID)
    assert_equal "testcreator-instagram-cxyz-ghi-34", video.slug
    assert_equal [{ "name" => "testcreator", "role" => "primary", "reason" => "no_match" },
                  { "name" => "Sample Singer", "role" => "featured", "reason" => "no_match" }], video.unresolved_credits
    assert(storage.puts.keys.all? { |k| k.start_with?("music_videos/testcreator/instagram_cxyz_ghi_34/source/") })
  end

  test "an Instagram digest records the creator, keeps the feat. name unresolved, and stores no caption" do
    storage = Storage.new
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: Shell.new(INFO), storage: storage, api: Api.new(self),
                              out: StringIO.new).call("#{PAGE}?igsh=secrettracker")
    end
    assert_response :created

    video = MusicVideo.find_by!(platform: "instagram", source_id: ID)
    assert_equal ["test-creator-instagram-cxyz-ghi-34", "Instagram #{ID}", PAGE, "#{KEY}.mp4", 19_000],
                 [video.slug, video.title, video.source_url, video.source_object_key, video.duration_ms]
    assert_equal [%w[test-creator primary]], video.music_video_artists.map { |c| [c.artist_slug, c.role] }
    assert_equal [{ "name" => "Sample Singer", "role" => "featured", "reason" => "no_match" }], video.unresolved_credits

    assert_equal ["#{KEY}.mp4", "#{KEY}.info.json"], storage.puts.keys
    stored = JSON.parse(storage.puts["#{KEY}.info.json"])
    assert_empty stored.keys - DigestVideo::INSTAGRAM_INFO_ALLOWLIST
    assert_equal PAGE, stored["webpage_url"]
    everything = storage.puts.values.join + video.attributes.to_json
    %w[secretcaption secrettag secretcomment secretsig secrettracker].each { |bad| refute_includes everything, bad }
  end
end
