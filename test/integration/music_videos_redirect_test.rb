require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [integration] /music_videos/... was the video section's path until the
# 2026-10-12 rename. Every old URL answers a redirect to the same path under
# /videos with its query string: 301 for a GET, 308 for any other verb so a
# stale tab's form keeps its method and body (config/routes.rb).
class MusicVideosRedirectTest < ActionDispatch::IntegrationTest
  def assert_moved(verb, old, status: verb == :get ? 301 : 308)
    public_send(verb, old)
    assert_response status, "#{verb.upcase} #{old}"
    assert_equal "http://www.example.com#{old.sub('/music_videos', '/videos')}", response.location, "#{verb.upcase} #{old}"
  end

  test "[integration] every page shape moves to the same path under /videos, query kept" do
    assert_moved :get, "/music_videos"
    assert_moved :get, "/music_videos?kind=movie_scene&page=2"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo/alt_videos/2"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo/alt_videos/2/links.json"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo/alt_videos/2/download?clip=1"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo/alt_videos/2/clips/3/download"
    assert_moved :get, "/music_videos/test-artist-a-tiled-demo/alt_videos/2/stitches/1.json"
  end

  test "[integration] a write to an old path keeps its verb (308), so a stale tab still lands" do
    assert_moved :post, "/music_videos/test-artist-a-tiled-demo/confirm_cast"
    assert_moved :patch, "/music_videos/test-artist-a-tiled-demo/performers/1"
    assert_moved :patch, "/music_videos/test-artist-a-tiled-demo/clips/2"
    assert_moved :post, "/music_videos/test-artist-a-tiled-demo/alt_videos"
    assert_moved :post, "/music_videos/test-artist-a-tiled-demo/alt_videos/1/clips/2/versions/1/primary"
    assert_moved :delete, "/music_videos/test-artist-a-tiled-demo/alt_videos/1/clips/2/regenerate"
    assert_moved :post, "/music_videos/test-artist-a-tiled-demo/alt_videos/1/clips/2/tiktok_drafts/9/refresh"
  end

  test "[integration] every walled /videos route is reachable from its old /music_videos path" do
    walked = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/videos")

      sample = path.gsub(/:\w+/, "x")
      [route.verb.presence || "GET", sample]
    end.uniq
    assert_operator walked.size, :>=, 20, "control: the /videos routes are drawn"

    walked.each do |verb, sample|
      assert_moved verb.split("|").first.downcase.to_sym, sample.sub("/videos", "/music_videos")
    end
  end

  test "[integration] only the old section prefix moves" do
    get "/music_videosx"
    assert_response :not_found
  rescue ActionController::RoutingError
    pass
  end

  test "[integration] the redirect tells a visitor nothing; /videos keeps its admin wall" do
    video = TiledVideo.seed!

    get "/music_videos/#{video.slug}"
    assert_response :moved_permanently
    follow_redirect!
    assert_redirected_to "/login", "a visitor lands on the wall, not the page"

    log_in_as users(:viewer)
    get "/music_videos/#{video.slug}"
    follow_redirect!
    assert_redirected_to root_path

    log_in_as users(:alex)
    get "/music_videos/#{video.slug}?tab=cast"
    follow_redirect!
    assert_response :success
    assert_equal "/videos/#{video.slug}?tab=cast", request.fullpath
  end

  test "[integration] a return_to minted before the rename is still honoured on a person's page" do
    assert_match PeopleController::RECAST_RETURN, "/videos/test-artist-a-tiled-demo#person-1"
    assert_match PeopleController::RECAST_RETURN, "/music_videos/test-artist-a-tiled-demo#person-1"
    assert_no_match PeopleController::RECAST_RETURN, "/admin"
    assert_no_match PeopleController::RECAST_RETURN, "https://evil.example/videos/x"
  end
end
