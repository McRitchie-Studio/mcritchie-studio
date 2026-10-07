# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [integration] The alt video asset zips (piece 17) end to end through the
# router: admin only, every clip's folder or one clip's, prompt.txt equal to
# the card's prompt, a README with the letters, streamed store-only and never
# gzipped by Rack::Deflater. Bytes come from the test env's FixtureFetcher.
# [component] The header's "Download all assets" and each clip card's
# "Download clip assets". Wholly synthetic people.
class AltVideoDownloadsControllerTest < ActionDispatch::IntegrationTest
  ROOT = "test-artist-b-lettered-demo_alt_1".freeze
  CLIP3 = "#{ROOT}/clip_03_0040-0105".freeze

  setup do
    @video = LetteredVideo.seed!
    @alt = @video.alt_videos.first
  end

  def zip_entries
    io = StringIO.new(response.body)
    entries = ZipKit::FileReader.read_zip_structure(io:)
    entries.to_h do |e|
      reader = e.extractor_from(io)
      out = +""
      out << reader.extract until reader.eof?
      [e.filename, [e.storage_mode, out.force_encoding(Encoding::UTF_8)]]
    end
  end

  test "non-admins download nothing" do
    get music_video_alt_video_download_path(@video, @alt)
    assert_redirected_to login_path
    log_in_as users(:viewer)
    get music_video_alt_video_download_path(@video, @alt)
    assert_redirected_to root_path
    get music_video_alt_video_clip_download_path(@video, @alt, 3)
    assert_redirected_to root_path
  end

  test "the all-assets zip holds one folder per clip, prompt.txt as the card shows it, and the README" do
    log_in_as users(:alex)
    get music_video_alt_video_path(@video, @alt)
    card_prompt = CGI.unescapeHTML(css_select("[data-test='alt-clip'][data-ordinal='3'] [data-test='clip-prompt']").sole.inner_html)

    get music_video_alt_video_download_path(@video, @alt), headers: { "Accept-Encoding" => "gzip" }
    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_match(/attachment; filename="#{ROOT}.zip"/, response.headers["Content-Disposition"])
    assert_nil response.headers["Content-Encoding"].to_s[/gzip/], "Rack::Deflater must not gzip the zip"
    assert_equal "private, no-store", response.headers["Cache-Control"]

    entries = zip_entries
    assert(entries.values.all? { |mode, _| mode.zero? }, "store-only")
    folders = entries.keys.filter_map { |k| k[%r{\A#{ROOT}/(clip_\d\d_\d{4}-\d{4})/}, 1] }.uniq
    assert_equal @alt.clips.size, folders.size
    assert_equal card_prompt, entries.fetch("#{CLIP3}/prompt.txt").last
    assert_includes entries.keys, "#{CLIP3}/source_clip.mp4"
    assert_includes entries.keys, "#{CLIP3}/frames/frame_1_ABC_0045.jpg"
    assert_equal "synthetic object #{@video.video_chunks.find_by!(ordinal: 3).object_key}\n", entries.fetch("#{CLIP3}/source_clip.mp4").last

    readme = entries.fetch("#{ROOT}/README.txt").last
    assert_includes readme, "  B  Person 2 (woman in the blue dress)  -> #4 Test Passer Epsilon > Home White"
    assert_includes readme, "Page          http://www.example.com/music_videos/test-artist-b-lettered-demo/alt_videos/1"
    # The seed's sheets are data: URIs, never fetched, so they are listed instead.
    assert_includes readme, "sheet_1_B_04_test-passer-epsilon_home-white.png  Sheet 1 · Person B · Test Passer Epsilon > Home White: " \
                            "the sheet image is not on an https public host"
    assert_equal "#{ROOT}/README.txt", entries.keys.last
  end

  test "a clip's zip holds that clip's folder and the README" do
    sheet = Artifact.newest_character_sheets([@alt.swap_set[2].appearance_slug]).values.first
    sheet.update_columns(image_url: "https://assets.mcritchie.studio/sheets/b.png")
    log_in_as users(:alex)
    get music_video_alt_video_clip_download_path(@video, @alt, 3)
    assert_response :success
    assert_match(/filename="#{ROOT}_clip_03.zip"/, response.headers["Content-Disposition"])

    entries = zip_entries
    assert_equal ["#{CLIP3}/frames/frame_1_ABC_0045.jpg", "#{CLIP3}/frames/frame_2_ABC_0054.jpg", "#{CLIP3}/prompt.txt",
                  "#{CLIP3}/sheets/sheet_1_B_04_test-passer-epsilon_home-white.png", "#{CLIP3}/source_clip.mp4",
                  "#{ROOT}/README.txt"].sort, entries.keys.sort
    assert_equal "synthetic url https://assets.mcritchie.studio/sheets/b.png\n", entries.fetch("#{CLIP3}/sheets/sheet_1_B_04_test-passer-epsilon_home-white.png").last
    assert_includes entries.fetch("#{ROOT}/README.txt").last, "one clip (Clip 3)"
  end

  test "an object that cannot be read is listed in the README and the zip still opens" do
    @video.video_chunks.find_by!(ordinal: 3).update_columns(object_key: "music_videos/test_artist_b/lettered_demo/chunks/missing.mp4")
    log_in_as users(:alex)
    get music_video_alt_video_clip_download_path(@video, @alt, 3)
    assert_response :success
    entries = zip_entries
    assert_not_includes entries.keys, "#{CLIP3}/source_clip.mp4"
    assert_includes entries.fetch("#{ROOT}/README.txt").last, "#{CLIP3}/source_clip.mp4  Clip 3 source clip: not in storage."
  end

  test "an unknown alt video or clip is a 404" do
    log_in_as users(:alex)
    get music_video_alt_video_clip_download_path(@video, @alt, 99)
    assert_response :not_found
    get music_video_alt_video_download_path(@video, 99)
    assert_response :not_found
  end

  test "the header offers every asset and each clip card its own" do
    log_in_as users(:alex)
    get music_video_alt_video_path(@video, @alt)
    assert_select "header [data-test='alt-video-download-all'][href=?]", music_video_alt_video_download_path(@video, @alt),
                  text: "Download all assets"
    assert_select "[data-test='alt-clip']", @alt.clips.size
    @alt.clips.each do |clip|
      assert_select "[data-test='alt-clip'][data-ordinal='#{clip.chunk_ordinal}'] [data-test='clip-handoff'] " \
                    "[data-test='clip-download-assets'][href=?]", music_video_alt_video_clip_download_path(@video, @alt, clip.chunk_ordinal),
                    text: "Download clip assets"
    end
  end
end
