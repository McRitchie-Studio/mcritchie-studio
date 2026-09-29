# frozen_string_literal: true

require "test_helper"

# [unit] AssetBrowser over a fixture listing: folder drill-down, paging, the
# bounded search, and the preview record. No bucket is touched.
class AssetBrowserTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/asset_browser_listing.yml")

  setup { @source = AssetBrowser::FixtureSource.new(FIXTURE) }

  test "the root lists top-level folders and root objects only" do
    listing = AssetBrowser.list(prefix: "", source: @source)

    assert_equal %w[artists/ music_videos/], listing.folders
    assert_equal %w[readme.txt], listing.files.map(&:key)
    assert_nil listing.next_token
  end

  test "a folder lists its subfolders and its own files" do
    listing = AssetBrowser.list(prefix: "music_videos/drake/hotline_bling/", source: @source)

    assert_equal %w[clips/ source/ stills/].map { |f| "music_videos/drake/hotline_bling/#{f}" }, listing.folders
    assert_equal %w[notes.txt], listing.files.map(&:name)
  end

  test "a page too small for the folder hands back a token that reaches the rest" do
    first = AssetBrowser.list(prefix: "artists/drake/", page_size: 1, source: @source)
    assert_equal %w[portrait_01.jpg], first.files.map(&:name)
    assert first.next_token

    second = AssetBrowser.list(prefix: "artists/drake/", token: first.next_token, page_size: 1, source: @source)
    assert_equal %w[portrait_02.png], second.files.map(&:name)
    assert_nil second.next_token
  end

  test "search matches file names across folders, case-insensitively" do
    result = AssetBrowser.search(query: "HOTLINE", prefix: "", source: @source)

    assert_equal [
      "music_videos/drake/hotline_bling/clips/hotline_bling_clip_01_chorus_vertical_0045_0102.mp4",
      "music_videos/drake/hotline_bling/source/drake_hotline_bling.mp4"
    ], result.matches.map(&:key)
    assert_equal 7, result.scanned
    assert result.complete
  end

  test "search matches the name, not the folders above it" do
    result = AssetBrowser.search(query: "drake", prefix: "artists/", source: @source)

    assert_empty result.matches
    assert_equal 2, result.scanned
  end

  test "search stops at its scan bound and says it did" do
    result = AssetBrowser.search(query: "o", prefix: "", scan_limit: 3, page_size: 2, source: @source)

    assert_equal 3, result.scanned
    assert_not result.complete
    assert_equal 3, result.scan_limit
  end

  test "preview reads the object's size, type and time, and signs a URL" do
    preview = AssetBrowser.preview("music_videos/drake/hotline_bling/source/drake_hotline_bling.mp4", source: @source)

    assert_equal 52_428_800, preview.entry.size
    assert_equal "video/mp4", preview.entry.mime
    assert_equal :video, preview.entry.kind
    assert_equal Time.utc(2026, 9, 28, 18), preview.entry.last_modified
    assert_includes preview.url, "drake_hotline_bling.mp4"
  end

  test "preview of a missing key is nil" do
    assert_nil AssetBrowser.preview("nope/missing.jpg", source: @source)
  end

  test "entries classify images, videos and everything else by extension" do
    kinds = %w[a.JPG b.png c.webp d.mp4 e.mov f.txt g].map { |k| AssetBrowser::Entry.new(key: k, size: 1, last_modified: nil).kind }

    assert_equal %i[image image image video video other other], kinds
  end

  test "prefixes normalize to a folder, and reject traversal" do
    assert_equal "", AssetBrowser.normalize_prefix(nil)
    assert_equal "", AssetBrowser.normalize_prefix("/")
    assert_equal "artists/drake/", AssetBrowser.normalize_prefix("/artists/drake")
    assert_equal "", AssetBrowser.normalize_prefix("artists/../secrets/")
  end

  test "breadcrumbs name every folder above the prefix" do
    assert_equal [ [ "music_videos", "music_videos/" ], [ "drake", "music_videos/drake/" ] ],
                 AssetBrowser.breadcrumbs("music_videos/drake/")
  end
end
