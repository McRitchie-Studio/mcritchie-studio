# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [component] One chunk row: the preview on its signed URL (or the unreachable
# state), the window, the overlap with the chunk before, the cast shape, the
# target and the filled prompt with Copy. A chunk has no seam and no decision.
class MusicVideoChunkViewTest < ActionView::TestCase
  helper MusicVideosHelper

  setup do
    @video = TiledVideo.seed!
    @chunks = @video.video_chunks.to_a
    @performers = @video.video_performers.includes(:artist).index_by(&:ordinal)
    @url = "https://signed.example/chunk.mp4?X-Amz-Signature=abc"
  end

  def render_row(chunk, urls: { chunk.object_key => @url }, overlap_ms: @video.chunk_overlap_ms)
    render partial: "music_videos/chunk", locals: { chunk:, performers: @performers, clip_urls: urls, overlap_ms: }
  end

  test "the row carries its signed preview, window, shape and target" do
    chunk = @chunks.second
    render_row(chunk)

    assert_select "#chunk-2[data-test='chunk-row'][data-ordinal='2'][x-data='clipRow()'][data-src=?]", @url do
      assert_select "[data-test='chunk-preview'][data-key=?] video[data-test='chunk-player'][preload='none']", chunk.object_key
      assert_select "[data-test='chunk-preview-button']", /Preview chunk 2/
      assert_select "[data-test='chunk-unreachable']", 0
      assert_select "h3", "Chunk 2"
      assert_select "[data-test='chunk-window']", /0:20–0:45\s+· 25\.0 s/
      assert_select "[data-test='chunk-shape']", "Solo + background"
      assert_select "[data-test='chunk-overlap']", "First 5 s repeat chunk 1"
      assert_select "[data-test='chunk-target']", /Person 1 · Test Artist A\s+\(man in the red jacket\)/
    end
  end

  test "the first chunk repeats nothing and the last one shows its shorter length" do
    render_row(@chunks.first)
    assert_select "[data-test='chunk-overlap']", 0
    assert_select "[data-test='chunk-window']", /0:00–0:25\s+· 25\.0 s/

    render_row(@chunks.last)
    assert_select "#chunk-4 [data-test='chunk-window']", /1:00–1:12\s+· 12\.0 s/
    assert_select "#chunk-4 [data-test='chunk-overlap']", "First 5 s repeat chunk 3"
  end

  test "the overlap chip reads the video's own tiling, and a plain cut has none" do
    render_row(@chunks.second, overlap_ms: 7_500)
    assert_select "[data-test='chunk-overlap']", "First 7.5 s repeat chunk 1"

    render_row(@chunks.third, overlap_ms: 0)
    assert_select "#chunk-3 [data-test='chunk-overlap']", 0
  end

  test "the filled prompt sits beside a Copy button" do
    chunk = @chunks.first
    render_row(chunk)

    assert_select "[data-test='chunk-prompt'][x-ref='prompt']", text: chunk.prompt
    assert_select "[data-test='chunk-prompt']", /Replace the man in the red jacket in this music video with \{athlete\}/
    copy = css_select("button[data-test='chunk-copy'][type='button']").sole
    assert_equal "copy()", copy["@click"]
  end

  test "a chunk shows no seam and offers no approve or reject" do
    render_row(@chunks.first)

    assert_select "[data-test='clip-seam']", 0
    assert_select "[data-test='clip-status']", 0
    assert_select "form", 0
    assert_no_match(/seam/i, rendered)
  end

  test "a chunk the store cannot sign says so instead of a player" do
    render_row(@chunks.last, urls: {})

    assert_select "video", 0
    assert_select "[data-test='chunk-unreachable']", /not reachable: tiled_demo_chunk_04_0100_0112\.mp4/
  end

  test "a window with no labelled artist falls back to the singer" do
    chunk = @chunks.first
    chunk.update_columns(target_performer: nil)
    render_row(chunk.reload)
    assert_select "[data-test='chunk-target']", /No labelled artist/
  end
end
