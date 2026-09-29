# frozen_string_literal: true

require "test_helper"

# [component] The /assets listing and preview partials, rendered from a listing.
class AssetBrowserListingViewTest < ActionView::TestCase
  FILE = AssetBrowser::Entry.new(key: "music_videos/drake/cover.jpg", size: 2048, last_modified: Time.utc(2026, 9, 1, 12))
  CLIP = AssetBrowser::Entry.new(key: "music_videos/drake/clip.mp4", size: 4_194_304, last_modified: Time.utc(2026, 9, 2))

  def render_listing(**overrides)
    render partial: "assets/listing",
           locals: { folders: [ "music_videos/drake/videos/" ], files: [ FILE ], prefix: "music_videos/drake/",
                     selected_key: nil, link_params: {}, show_folder: false }.merge(overrides)
  end

  test "folders render before files, each folder linking one level down" do
    render_listing

    assert_select "[data-test='asset-folder']", 1 do
      assert_select "a[href=?]", asset_browser_path(prefix: "music_videos/drake/videos/"), text: /videos/
    end
    assert_select "[data-test='asset-file'][data-key='music_videos/drake/cover.jpg']", 1 do
      assert_select "a", text: /cover\.jpg/
      assert_select "[data-test='asset-size']", "2 KB"
      assert_select "[data-test='asset-kind']", "image"
    end
  end

  test "the selected file is marked current" do
    render_listing(selected_key: FILE.key)

    assert_select "[data-test='asset-file'][aria-current='true']", 1
  end

  test "an empty folder says so" do
    render_listing(folders: [], files: [])

    assert_select "[data-test='asset-empty']", /No objects/
  end

  test "search results show the folder each match lives in" do
    render_listing(folders: [], show_folder: true)

    assert_select "[data-test='asset-file-folder']", "music_videos/drake/"
  end

  test "a video preview is a video element on the signed URL, with its facts" do
    render partial: "assets/preview", locals: { preview: AssetBrowser::Preview.new(entry: CLIP, url: "https://signed.example/clip.mp4?X-Amz-Signature=abc") }

    assert_select "[data-test='asset-preview'] video[src='https://signed.example/clip.mp4?X-Amz-Signature=abc'][controls]"
    assert_select "[data-test='asset-preview-size']", "4 MB"
    assert_select "[data-test='asset-preview-type']", "video/mp4"
    assert_select "[data-test='asset-preview-modified'] time[datetime='2026-09-02T00:00:00Z']"
  end

  test "an image preview is an img, and anything else offers only the signed download" do
    render partial: "assets/preview", locals: { preview: AssetBrowser::Preview.new(entry: FILE, url: "https://signed.example/cover.jpg") }
    assert_select "[data-test='asset-preview'] img[src='https://signed.example/cover.jpg']"

    other = AssetBrowser::Entry.new(key: "notes.txt", size: 5, last_modified: nil)
    render partial: "assets/preview", locals: { preview: AssetBrowser::Preview.new(entry: other, url: "https://signed.example/notes.txt") }
    assert_select "[data-test='asset-preview-none']"
    assert_select "a[href='https://signed.example/notes.txt']", /Open/
  end
end
