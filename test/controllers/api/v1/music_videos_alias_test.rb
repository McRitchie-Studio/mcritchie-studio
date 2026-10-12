require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

module Api
  module V1
    # [integration] /api/v1/music_videos was the pipeline API's path until the
    # 2026-10-12 rename; scripts installed before it still call it. It is an
    # alias served by the same controllers, never a redirect (a POST must not
    # 301), and it takes the record under its old "music_video" key too.
    class MusicVideosAliasTest < ActionDispatch::IntegrationTest
      KEY = "music_videos/test_artist_a/alias_song/source/test_artist_a_alias_song.mp4".freeze

      def auth_headers
        { "Authorization" => "Bearer #{Rails.application.message_verifier('api_auth').generate('test', purpose: :api_auth, expires_in: 1.hour)}" }
      end

      def payload(source_id)
        { platform: "youtube", source_url: "https://www.youtube.com/watch?v=#{source_id}", source_id:,
          title: "Test Artist A - Alias Song #{source_id}", uploader: "Test Records", credited_artists: [],
          duration_ms: 60_000, source_object_key: KEY.sub("alias_song", "alias_song_#{source_id.downcase}"),
          caption_timing: { cues: [], sections: [] } }
      end

      def body = JSON.parse(response.body)

      test "[unit] every /api/v1/videos route has a /api/v1/music_videos twin on the same controller action" do
        routes = Rails.application.routes.routes.map { |r| [r.verb, r.path.spec.to_s, r.defaults.values_at(:controller, :action)] }
        canonical = routes.select { |_, path, _| path.start_with?("/api/v1/videos") }
        assert_operator canonical.size, :>=, 9, "control: the canonical API routes are drawn"

        canonical.each do |verb, path, target|
          twin = path.sub("/api/v1/videos", "/api/v1/music_videos")
          assert_includes routes, [verb, twin, target], "#{verb} #{path} has no alias at #{twin}"
        end
      end

      test "[integration] GET answers under the old path exactly as under the new one" do
        video = TiledVideo.seed!

        get "/api/v1/videos/#{video.slug}", headers: auth_headers
        assert_response :ok
        canonical = response.body

        get "/api/v1/music_videos/#{video.slug}", headers: auth_headers
        assert_response :ok, "an alias, not a redirect"
        assert_equal canonical, response.body
        assert_equal video.slug, body.dig("data", "slug")
      end

      test "[integration] POST creates under the old path and the old body key, without a redirect" do
        assert_difference -> { Video.count } => 1 do
          post "/api/v1/music_videos", params: { music_video: payload("OldKey1") }, headers: auth_headers, as: :json
        end
        assert_response :created
        assert_equal "music_video", body.dig("data", "kind")

        assert_difference -> { Video.count } => 1 do
          post "/api/v1/music_videos", params: { video: payload("NewKey2").merge(kind: "movie_scene") }, headers: auth_headers, as: :json
        end
        assert_response :created
        assert_equal "movie_scene", body.dig("data", "kind")

        assert_difference -> { Video.count } => 1 do
          post "/api/v1/videos", params: { music_video: payload("OldKey3") }, headers: auth_headers, as: :json
        end
        assert_response :created, "an old script pointed at the new path still lands"

        assert_no_difference -> { Video.count } do
          post "/api/v1/music_videos", params: { other: payload("Neither4") }, headers: auth_headers, as: :json
        end
        assert_response :bad_request
      end

      test "[integration] the nested writes and reads answer under the old path" do
        video = TiledVideo.seed!
        AltVideo.build_from!(video)

        get "/api/v1/videos/#{video.slug}/alt_videos/1/stitches", headers: auth_headers
        assert_response :ok
        canonical = response.body
        get "/api/v1/music_videos/#{video.slug}/alt_videos/1/stitches", headers: auth_headers
        assert_response :ok
        assert_equal canonical, response.body

        post "/api/v1/music_videos/#{video.slug}/performers", params: { performers: [] }, headers: auth_headers, as: :json
        assert_includes [200, 409, 422], response.status, "the alias reaches the performers action: #{response.body}"
        assert_not response.redirect?

        post "/api/v1/music_videos/#{video.slug}/alt_videos/1/stitches", headers: auth_headers, as: :json
        assert_not response.redirect?
        assert_includes [201, 409, 422], response.status, response.body
      end

      test "[integration] the alias still needs the token" do
        get "/api/v1/music_videos/anything"
        assert_response :unauthorized
        post "/api/v1/music_videos", params: { music_video: payload("NoToken5") }, as: :json
        assert_response :unauthorized
      end
    end
  end
end
