require "test_helper"
require_relative "../../bin/lib/digest_video"

# [integration] A YouTube digest whose caption track is refused (HTTP 429) still
# records through the real hub API, with empty timing. yt-dlp, ffprobe and R2
# are fakes.
class DigestVideoYoutubeIntegrationTest < ActionDispatch::IntegrationTest
  ID = "Ab3_cd-EF9g".freeze
  URL = "https://www.youtube.com/watch?v=#{ID}".freeze
  KEY = "music_videos/test_artist/test_song/source/test_artist_test_song.mp4".freeze
  INFO = { "id" => ID, "title" => "Test Artist - Test Song (Official Video)", "uploader" => "Test Artist",
           "webpage_url" => URL, "extractor" => "youtube" }.freeze
  CAPTION_429 = "ERROR: Unable to download video subtitles for 'en-zh-Hans-x': HTTP Error 429: Too Many Requests".freeze

  class Shell
    attr_reader :ytdlp_calls

    def initialize = @ytdlp_calls = []

    def call(*cmd)
      if File.basename(cmd.first) == "yt-dlp"
        @ytdlp_calls << cmd
        return ["", CAPTION_429, false] if cmd.include?("--write-subs")

        dir = cmd[cmd.index("-P") + 1]
        File.write(File.join(dir, "#{ID}.mp4"), "video")
        File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(INFO))
        return ["", "", true]
      end
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264" },
                                   { "codec_type" => "audio", "codec_name" => "aac" }],
                     "format" => { "duration" => "200.0" }), "", true]
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

  setup { Artist.create!(slug: "test-artist", name: "Test Artist", kind: "person") }

  test "a refused caption track records the video with empty timing" do
    shell = Shell.new
    storage = Storage.new
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: shell, storage: storage, api: Api.new(self),
                              out: StringIO.new).call(URL)
    end
    assert_response :created
    assert_equal [true, false], shell.ytdlp_calls.map { |c| c.include?("--write-subs") }

    video = MusicVideo.find_by!(platform: "youtube", source_id: ID)
    assert_equal ["#{KEY}", 200_000, { "cues" => [], "sections" => [] }],
                 [video.source_object_key, video.duration_ms, video.caption_timing]
    assert_equal [%w[test-artist primary]], video.music_video_artists.map { |c| [c.artist_slug, c.role] }
    assert_includes storage.puts.keys, KEY
  end
end
