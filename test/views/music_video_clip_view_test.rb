# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s

# [component] One clip row: the preview on its signed URL (or the unreachable
# state), the window, seam and cast-shape chips, the target, the filled prompt
# with its Copy button, and Approve / Reject.
class MusicVideoClipViewTest < ActionView::TestCase
  helper MusicVideosHelper

  setup do
    @video = NightCallClips.seed!
    @clip = @video.video_clips.find_by!(ordinal: 2)
    @url = "https://signed.example/clip2.mp4?X-Amz-Signature=abc"
  end

  def render_row(clip = @clip, urls: { @clip.object_key => @url })
    render partial: "music_videos/clip", locals: { clip:, video: @video, clip_urls: urls }
  end

  test "the row carries its signed preview, window, chips and target" do
    render_row

    assert_select "[data-test='clip-row'][data-ordinal='2'][data-status='proposed'][x-data='clipRow()'][data-src=?]", @url do
      assert_select "[data-test='clip-preview'][data-key=?] video[data-test='clip-player'][preload='none']", @clip.object_key
      assert_select "[data-test='clip-preview-button']", /Preview clip 2/
      assert_select "[data-test='clip-unreachable']", 0
      assert_select "[data-test='clip-window']", /1:48–2:12\s+· 24\.8 s · seam at 2:03/
      assert_select "[data-test='clip-seam']", "Singer change"
      assert_select "[data-test='clip-shape']", "Duo + background"
      assert_select "[data-test='clip-target']", /Person 4 · Test Artist C\s+\(couch\)/
      assert_select "[data-test='clip-status']", "Proposed"
    end
  end

  test "the filled prompt sits beside a Copy button" do
    render_row

    assert_select "[data-test='clip-prompt'][x-ref='prompt']", text: @clip.prompt
    assert_select "[data-test='clip-prompt']", /Replace the person in the couch scenes in this music video with \{athlete\}/
    copy = css_select("button[data-test='clip-copy'][type='button']").sole
    assert_equal "copy()", copy["@click"]
    assert_match "Copy", copy.text
  end

  test "approve and reject patch this clip; the current decision is disabled" do
    @clip.update!(status: "approved")
    render_row

    form = "form[action='/music_videos/steve-aoki-night-call-clips/clips/2']"
    assert_select "#{form}:has(input[name='status'][value='approved']) button[disabled]", "Approve"
    assert_select "#{form}:has(input[name='status'][value='rejected']) button:not([disabled])", "Reject"
    assert_select "[data-test='clip-status']", "Approved"
  end

  test "a clip the store cannot sign says so instead of a player" do
    render_row(urls: {})

    assert_select "video", 0
    assert_select "[data-test='clip-unreachable']", /not reachable: night_call_clips_clip_02_singer_change/
  end

  test "a window with no labelled artist falls back to the singer" do
    @clip.update_columns(target_performer: nil)
    render_row(@clip.reload)
    assert_select "[data-test='clip-target']", /Nobody in this window is labelled or recast; the prompt says “the singer”/
  end
end
