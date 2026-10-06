require "test_helper"
require_relative "../../bin/lib/chunk_tiling"
require_relative "../../bin/lib/digest_video"

# [integration] bin/digest-video's runner with the shared chunk tiler, posting
# through the real hub API: a new source is recorded and cut into chunks before
# anyone is cast; a re-digest cuts nothing; the vision pass and the cast confirm
# label the chunks the digest cut blind. yt-dlp, ffmpeg, ffprobe and R2 are fakes.
class DigestVideoTilesIntegrationTest < ActionDispatch::IntegrationTest
  ID = "Zz9ChunkDemo".freeze
  URL = "https://www.youtube.com/watch?v=#{ID}".freeze
  INFO = { "id" => ID, "title" => "Test Artist B - Chunk Demo", "uploader" => "Test Artist B", "duration" => 72,
           "webpage_url" => URL, "extractor" => "youtube" }.freeze

  # yt-dlp writes the download; ffprobe answers JSON for the digest and a bare
  # number for the tiler (two different probes of one 72 s file); ffmpeg cuts.
  class Shell
    attr_reader :cuts

    def initialize = @cuts = 0

    def call(*cmd)
      case File.basename(cmd.first)
      when "yt-dlp" then download(cmd[cmd.index("-P") + 1])
      when "ffprobe"
        return ["72.000000\n", "", true] if cmd.include?("csv=p=0")

        [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264" },
                                     { "codec_type" => "audio", "codec_name" => "aac" }],
                       "format" => { "duration" => "72.0" }), "", true]
      else
        @cuts += 1
        File.write(cmd.last, "chunk")
        ["", "", true]
      end
    end

    def download(dir)
      File.write(File.join(dir, "#{ID}.mp4"), "video")
      File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(INFO))
      ["", "", true]
    end
  end

  class Storage
    attr_reader :keys

    def initialize = @keys = []

    def put(key, _path, _content_type) = @keys << key
  end

  # The runner's ApiClient, answered by this app instead of a socket.
  Api = Struct.new(:session) do
    def authenticate = true

    def create(payload) = post("/api/v1/music_videos", { music_video: payload })

    def post(path, body)
      token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)
      session.post path, params: body, as: :json, headers: { "Authorization" => "Bearer #{token}" }
      raise DigestVideo::Failure, session.response.body unless session.response.successful?

      JSON.parse(session.response.body).fetch("data")
    end
  end

  def digest(shell:, storage:, **tiling)
    Dir.mktmpdir do |dir|
      api = Api.new(self)
      tiler = ChunkTiling::Runner.new(api:, storage:, shell:, out: StringIO.new, **tiling)
      DigestVideo::Runner.new(workdir: dir, shell:, storage:, api:, out: StringIO.new, tiler:).call(URL)
    end
  end

  test "a new source is cut into chunks before the cast, and a re-digest cuts nothing" do
    storage = Storage.new
    shell = Shell.new
    digest(shell:, storage:)

    video = MusicVideo.find_by!(platform: "youtube", source_id: ID)
    assert_equal "digested", video.stage, "chunks never move the stage, and nobody is cast"
    assert_equal [[1, 0, 25_000], [2, 20_000, 45_000], [3, 40_000, 65_000], [4, 60_000, 72_000]],
                 video.video_chunks.pluck(:ordinal, :start_ms, :end_ms)
    assert_equal({ chunk_ms: 25_000, overlap_ms: 5_000 }, video.chunk_tiling)
    assert_equal [MusicVideos::ClipPrompt.fill(target: nil)], video.video_chunks.pluck(:prompt).uniq, "the generic prompt"
    assert_equal 4, shell.cuts
    assert_equal 6, storage.keys.size, "the source, its info.json and four chunks"
    assert_empty video.clip_candidates

    ids = video.video_chunks.pluck(:id)
    again = Shell.new
    digest(shell: again, storage:)
    assert_response :ok # the record was already there
    assert_equal ids, video.reload.video_chunks.pluck(:id), "the same rows: nothing replaced"
    assert_equal 0, again.cuts
    assert_equal 8, storage.keys.size, "only the source and its info.json again"
  end

  test "a re-digest at another tiling keeps the chunks unless told to replace them" do
    storage = Storage.new
    digest(shell: Shell.new, storage:)
    video = MusicVideo.find_by!(platform: "youtube", source_id: ID)

    digest(shell: Shell.new, storage:, chunk_ms: 15_000, overlap_ms: 5_000)
    assert_equal 4, video.reload.video_chunks.count
    assert_equal 25_000, video.chunk_ms

    digest(shell: Shell.new, storage:, chunk_ms: 15_000, overlap_ms: 5_000, replace: true)
    assert_equal 7, video.reload.video_chunks.count
    assert_equal({ chunk_ms: 15_000, overlap_ms: 5_000 }, video.chunk_tiling)
  end

  test "the vision pass and the cast confirm label the chunks the digest cut blind" do
    digest(shell: Shell.new, storage: Storage.new)
    video = MusicVideo.find_by!(platform: "youtube", source_id: ID)

    performers = [{ "ordinal" => 1, "label" => "man in the red jacket", "still_object_keys" => [],
                    "sightings" => [3, 6, 9, 12].map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } } },
                  { "ordinal" => 2, "label" => "woman in the doorway", "still_object_keys" => [],
                    "sightings" => [{ "t_ms" => 50_000, "visibility" => "partial" }] }]
    Api.new(self).post("/api/v1/music_videos/#{video.slug}/performers", { performers: })

    chunks = video.reload.video_chunks
    assert_equal [[1], [], [2], []], chunks.map(&:performer_ordinals), "who is on screen, from the sightings"
    assert_equal %w[unknown unknown unknown unknown], chunks.map(&:cast_shape), "nobody is named yet, so no principal"

    artist = Artist.create!(slug: "test-artist-b", name: "Test Artist B", kind: "person")
    video.video_performers.find_by!(ordinal: 1).update!(artist_slug: artist.slug)
    video.confirm_cast!

    chunk = video.reload.video_chunks.first
    assert_equal ["solo", 1], [chunk.cast_shape, chunk.target_performer]
    assert_includes chunk.prompt, "the man in the red jacket"
  end
end
