# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [component] One chunk row: the preview on its signed URL (or the unreachable
# state), the window, the overlap with the chunk before, the cast shape, the
# target and the filled prompt with Copy; the hand-off (source download, the
# recast look's character sheet); the generated takes with their upload; and
# the regenerate control. A chunk has no seam and no approve or reject.
class MusicVideoChunkViewTest < ActionView::TestCase
  helper MusicVideosHelper

  setup do
    @video = TiledVideo.seed!
    @chunks = @video.video_chunks.to_a
    @url = "https://signed.example/chunk.mp4?X-Amz-Signature=abc"
  end

  def render_row(chunk, urls: { chunk.object_key => @url }, overlap_ms: @video.chunk_overlap_ms, downloads: nil, sheets: {})
    downloads ||= { chunk.object_key => "#{@url}&response-content-disposition=attachment" }
    render partial: "music_videos/chunk", locals: { chunk:, video: @video, clip_urls: urls, overlap_ms:, downloads:, sheets: }
  end

  def recast_first_performer!(descriptor = "Away White")
    athlete = RecastVideo.athlete!
    look = athlete.appearances.live.find_by!(descriptor:)
    MusicVideos::RecastPerformer.new(@video.video_performers.first).call(person_slug: athlete.slug, appearance_slug: look.slug)
    look
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
    assert_select "[data-test='chunk-prompt']", /Replace the man in the red jacket in this video with \{athlete\}/
    copy = css_select("button[data-test='chunk-copy'][type='button']").sole
    assert_equal "copy()", copy["@click"]
  end

  test "a chunk shows no seam and offers no approve or reject" do
    render_row(@chunks.first)

    assert_select "[data-test='clip-seam']", 0
    assert_select "[data-test='clip-status']", 0
    assert_select "[data-test='clip-decision']", 0
    assert_select "button, input[type='submit']", text: /Approve|Reject/, count: 0
    assert_select "form[action*='/clips/']", 0
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
    assert_select "[data-test='chunk-target']", /Nobody in this window is labelled or recast; the prompt says “the main person on screen”/
  end

  test "a target nobody has recast says the athlete is still a blank and links to their card" do
    render_row(@chunks.first)

    assert_select "[data-test='chunk-recast']", 0
    assert_select "[data-test='chunk-recast-open']", /No athlete chosen for\s+Person 1\s+yet, so the prompt leaves \{athlete\} blank/ do
      assert_select "a[href='#person-1']", "Person 1"
    end
  end

  test "a recast target shows the athlete and look, and the prompt names them" do
    athlete = RecastVideo.athlete!
    MusicVideos::RecastPerformer.new(@video.video_performers.first)
                                .call(person_slug: athlete.slug, appearance_slug: athlete.appearances.live.find_by!(descriptor: "Away White").slug)
    render_row(@video.reload.video_chunks.first)

    assert_select "[data-test='chunk-target']", /Person 1 · Test Artist A\s+\(man in the red jacket\)/
    assert_select "[data-test='chunk-recast']", /Replaced by\s+Test Athlete Alpha &gt; Away White|Replaced by\s+Test Athlete Alpha > Away White/
    assert_select "[data-test='chunk-recast-open']", 0
    assert_select "[data-test='chunk-prompt']", /in this video with Test Athlete Alpha, the football player.*like the Away White model provided/m
  end

  test "a cinematic chunk with no labelled target takes the recast person in its window" do
    video = RecastVideo.seed!
    athlete = RecastVideo.athlete!
    render_row(video.video_chunks.first, overlap_ms: 5_000)
    assert_select "[data-test='chunk-target']", /Nobody in this window is labelled or recast/

    MusicVideos::RecastPerformer.new(video.video_performers.second)
                                .call(person_slug: athlete.slug, appearance_slug: athlete.appearances.first.slug)
    render_row(video.reload.video_chunks.first, overlap_ms: 5_000)
    assert_select "[data-test='chunk-target']", /Person 2\s+\(woman in the doorway\)/
    assert_select "[data-test='chunk-recast']", /Test Athlete Alpha > Home Blue/
  end

  test "the hand-off offers the source chunk as a download beside the prompt" do
    chunk = @chunks.second
    render_row(chunk)

    assert_select "[data-test='chunk-handoff']" do
      link = css_select("a[data-test='chunk-source-download']").sole
      assert_equal "Download source chunk", link.text.strip
      assert_equal "tiled_demo_chunk_02_0020_0045.mp4", link["download"]
      assert_includes link["href"], "response-content-disposition=attachment"
    end
    assert_select "[data-test='chunk-prompt']", 1
    assert_select "[data-test='chunk-copy']", 1
  end

  test "the hand-off says so when the source chunk cannot be signed" do
    render_row(@chunks.first, downloads: {})

    assert_select "[data-test='chunk-source-download']", 0
    assert_select "[data-test='chunk-source-unreachable']", /Source chunk not reachable/
  end

  test "the hand-off links the recast look's character sheet" do
    look = recast_first_performer!
    sheet = Artifact.create!(kind: "character_sheet", image_url: "https://cdn.example/sheets/away_white.png", source: "higgsfield")
    render_row(@video.reload.video_chunks.first, sheets: { look.slug => sheet })

    link = css_select("a[data-test='chunk-look-sheet']").sole
    assert_equal "https://cdn.example/sheets/away_white.png", link["href"]
    assert_equal "_blank", link["target"]
    assert_equal look.slug, link["data-look"]
    assert_match(/Character sheet · Test Athlete Alpha > Away White/, link.text.squish)
    assert_select "[data-test='chunk-look-sheet-missing'], [data-test='chunk-look-none']", 0
  end

  test "a recast look with no sheet yet says so and links to the athlete" do
    recast_first_performer!
    render_row(@video.reload.video_chunks.first)

    assert_select "[data-test='chunk-look-sheet']", 0
    assert_select "[data-test='chunk-look-sheet-missing']", /No character sheet for Test Athlete Alpha > Away White yet/ do
      assert_select "a[href=?]", person_path(RecastVideo.athlete!.slug)
    end
  end

  test "a chunk nobody is recast in has no look to hand off" do
    render_row(@chunks.first)

    assert_select "[data-test='chunk-look-none']", /nobody in this chunk is recast yet/
  end

  test "a chunk with no take says the preview plays its source, and offers the upload" do
    chunk = @chunks.second
    render_row(chunk)

    assert_select "#chunk-2[data-take=''][data-flagged='false']"
    assert_select "[data-test='chunk-take-state']", "No take yet"
    assert_select "[data-test='chunk-takes'][data-count='0'] [data-test='chunk-takes-empty']", /plays this chunk's source/
    assert_select "form[data-test='chunk-take-form'][enctype='multipart/form-data'][method='post'][action=?]",
                  music_video_chunk_takes_path(@video, 2) do
      assert_select "input[type='file'][name='file'][required][accept='video/mp4,.mp4']", 1
      assert_select "button[type='submit'][data-test='chunk-take-submit']", /Upload take/
    end
  end

  test "takes list newest first, the current one marked and the others offering make current" do
    chunk = @chunks.second
    first = TiledVideo.take!(chunk, number: 1, at: 2.minutes.ago, byte_size: 12_582_912)
    second = TiledVideo.take!(chunk, number: 2, at: 1.minute.ago)
    chunk = @video.reload.video_chunks.second
    render_row(chunk, urls: { chunk.object_key => @url, first.object_key => "https://signed.example/take1.mp4", second.object_key => "https://signed.example/take2.mp4" })

    assert_select "#chunk-2[data-take='2']"
    assert_select "[data-test='chunk-take-state']", "Take 2 current"
    assert_equal %w[2 1], css_select("[data-test='chunk-take']").map { |li| li["data-number"] }
    assert_select "[data-test='chunk-take'][data-number='2'][data-current='true']" do
      assert_select ".badge", "Current"
      assert_select "form", 0
      assert_select "a[data-test='chunk-take-open'][href='https://signed.example/take2.mp4']", "Open"
    end
    assert_select "[data-test='chunk-take'][data-number='1'][data-current='false']", /Take 1\s+· 12\.0 MB/ do
      assert_select "form[data-test='chunk-take-current'][action=?]", current_music_video_chunk_take_path(@video, 2, 1)
      assert_select "a[data-test='chunk-take-open'][href='https://signed.example/take1.mp4']", 1
    end
    assert_select "[data-test='chunk-takes-empty']", 0
  end

  test "an unflagged chunk offers request regenerate with an optional note" do
    render_row(@chunks.third)

    assert_select "[data-test='chunk-flag']", 0
    assert_select "form[data-test='chunk-regenerate-form'][method='post'][action=?]", music_video_chunk_regenerate_path(@video, 3) do
      assert_select "input[type='text'][name='note'][maxlength='280']:not([required])", 1
      assert_select "button[type='submit']", "Request regenerate"
    end
  end

  test "a flagged chunk shows its note and a clear button instead" do
    @chunks.third.request_regenerate!("the jersey flickers")
    render_row(@chunks.third)

    assert_select "#chunk-3[data-flagged='true'] [data-test='chunk-flag']", "Regenerate requested"
    assert_select "[data-test='chunk-regenerate-note']", /Regenerate requested: the jersey flickers\s+The next uploaded take clears it/
    assert_select "[data-test='chunk-regenerate-form']", 0
    assert_select "form[data-test='chunk-regenerate-clear'][action=?]", music_video_chunk_regenerate_path(@video, 3) do
      assert_select "input[name='_method'][value='delete']", 1
    end
  end

  test "a flag with no note reads cleanly" do
    @chunks.third.request_regenerate!
    render_row(@chunks.third)

    assert_select "[data-test='chunk-regenerate-note']", /\ARegenerate requested\s+The next uploaded take clears it\.\z/
  end
end
