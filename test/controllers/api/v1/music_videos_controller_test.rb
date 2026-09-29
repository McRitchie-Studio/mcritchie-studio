require "test_helper"

module Api
  module V1
    # [integration] The digest API: creates the record and its artist links, and
    # refuses any payload that carries caption text.
    class MusicVideosControllerTest < ActionDispatch::IntegrationTest
      KEY = "music_videos/steve_aoki/night_call/source/steve_aoki_night_call_feat_lil_yachty_migos.mp4".freeze

      setup do
        Artist.create!(slug: "steve-aoki", name: "Steve Aoki", kind: "person")
        yachty = Artist.create!(slug: "lil-yachty", name: "Lil Yachty", kind: "person")
        ArtistAlias.create!(artist: yachty, name: "Lil Boat")
        Artist.create!(slug: "migos", name: "Migos", kind: "group")
      end

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth)}" }
      end

      def payload(**overrides)
        {
          platform: "youtube",
          source_url: "https://www.youtube.com/watch?v=Sa7GSJJ_lOo",
          source_id: "Sa7GSJJ_lOo",
          title: "Steve Aoki - Night Call feat. Lil Yachty & Migos (Official Video) [Ultra Music]",
          uploader: "Ultra Records",
          credited_artists: [],
          duration_ms: 243_000,
          source_object_key: KEY,
          info_object_key: KEY.sub(/\.mp4\z/, ".info.json"),
          caption_timing: {
            cues: [{ start_ms: 5_000, end_ms: 7_000 }],
            sections: [{ kind: "vocal", start_ms: 5_000, end_ms: 7_000 }]
          }
        }.merge(overrides)
      end

      def post_video(**overrides)
        post api_v1_music_videos_path, params: { music_video: payload(**overrides) }, headers: auth_headers, as: :json
      end

      def data = JSON.parse(response.body)["data"]

      test "creates the record and links primary and featured artists" do
        assert_difference -> { MusicVideo.count } => 1, -> { MusicVideoArtist.count } => 3 do
          post_video
        end
        assert_response :created

        video = MusicVideo.find_by!(slug: "steve-aoki-night-call")
        assert_equal %w[music_video youtube Sa7GSJJ_lOo digested], [video.kind, video.platform, video.source_id, video.stage]
        assert_equal 243_000, video.duration_ms
        assert_equal KEY, video.source_object_key
        assert_equal [["lil-yachty", "featured", 1], ["migos", "featured", 2], ["steve-aoki", "primary", 1]],
                     video.music_video_artists.map { |c| [c.artist_slug, c.role, c.position] }.sort
        assert_equal [], video.unresolved_credits
        assert_equal "group", data["artists"].find { |a| a["slug"] == "migos" }["kind"]
      end

      test "an alias resolves and an unknown name is reported, not created" do
        assert_no_difference -> { Artist.count } do
          post_video(title: "Steve Aoki - Night Call feat. Lil Boat & Nobody Known (Official Video)")
        end
        assert_response :created
        assert_equal %w[steve-aoki lil-yachty], data["artists"].map { |a| a["slug"] }
        assert_equal [{ "name" => "Nobody Known", "role" => "featured", "reason" => "no_match" }], data["unresolved_credits"]
      end

      test "an exact name wins over another artist's alias" do
        other = Artist.create!(slug: "not-migos", name: "Somebody", kind: "person")
        ArtistAlias.create!(artist: other, name: "Migos")
        post_video
        assert_includes data["artists"].map { |a| a["slug"] }, "migos"
      end

      test "a repeat digest answers 200 with the existing record" do
        post_video
        assert_no_difference -> { MusicVideo.count } do
          post_video
        end
        assert_response :ok
        assert_equal "steve-aoki-night-call", data["slug"]
      end

      test "GET by slug returns the record without lyric text" do
        post_video
        get api_v1_music_video_path("steve-aoki-night-call"), headers: auth_headers, as: :json
        assert_response :ok
        assert_equal [{ "start_ms" => 5_000, "end_ms" => 7_000 }], data["caption_timing"]["cues"]
      end

      test "rejects caption text inside a cue" do
        assert_no_difference -> { MusicVideo.count } do
          post_video(caption_timing: { cues: [{ start_ms: 1, end_ms: 2, text: "a lyric line" }], sections: [] })
        end
        assert_response :unprocessable_entity
        assert_equal "VALIDATION_FAILED", JSON.parse(response.body)["error_code"]
      end

      test "rejects a text-bearing section kind" do
        post_video(caption_timing: { cues: [], sections: [{ kind: "we ride at dawn", start_ms: 1, end_ms: 2 }] })
        assert_response :unprocessable_entity
      end

      test "rejects a caption or lyrics key anywhere in the payload" do
        assert_no_difference -> { MusicVideo.count } do
          post_video(lyrics: "a lyric line")
        end
        assert_response :unprocessable_entity
        assert_equal "UNPERMITTED_KEYS", JSON.parse(response.body)["error_code"]

        post_video(caption_timing: { cues: [], sections: [], transcript: "words" })
        assert_response :unprocessable_entity
      end

      test "requires a token" do
        post api_v1_music_videos_path, params: { music_video: payload }, as: :json
        assert_response :unauthorized
      end
    end
  end
end
