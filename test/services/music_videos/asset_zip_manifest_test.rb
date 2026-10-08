require "test_helper"
require_relative "../../support/url_guard_world"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [unit] The alt video asset zip's manifest (piece 17): folder and file names,
# prompt.txt as the card builds it, frames in card order, sheets in the
# prompt's order, and the README's letters and missing list. No I/O. Wholly
# synthetic people (db/seeds/data/lettered_video.rb).
class MusicVideosAssetZipManifestTest < ActiveSupport::TestCase
  include UrlGuardWorld

  Manifest = MusicVideos::AssetZip::Manifest
  ROOT = "test-artist-b-lettered-demo_alt_1".freeze
  CLIP3 = "#{ROOT}/clip_03_0040-0105".freeze

  setup do
    @video = LetteredVideo.seed!
    @alt = @video.alt_videos.first
    @swaps = @alt.swap_set
    # Production sheets live on an https host; the seed's are data: URIs.
    @swaps.appearance_slugs.each_with_index do |slug, i|
      Artifact.newest_character_sheets([slug])[slug].update_columns(image_url: "https://assets.mcritchie.studio/sheets/look-#{i}.png")
    end
  end

  def manifest(**) = Manifest.for(AltVideo.find(@alt.id), **)

  def paths(m = manifest) = m.entries.map(&:path)

  def chunk(ordinal) = @video.video_chunks.reload.find { |c| c.ordinal == ordinal }

  test "one folder per clip, named by number and window, each with the source clip and the prompt" do
    m = manifest
    folders = @alt.clips.map { |clip| "#{ROOT}/#{Manifest.clip_folder_name(clip)}" }
    assert_includes folders, CLIP3
    assert_equal folders, folders.sort, "folders sort in clip order"
    folders.each do |folder|
      assert_includes paths(m), "#{folder}/source_clip.mp4"
      assert_includes paths(m), "#{folder}/prompt.txt"
    end
    source = m.entries.find { |e| e.path == "#{CLIP3}/source_clip.mp4" }
    assert_equal [:object, chunk(3).object_key], [source.kind, source.source]
    assert(paths(m).none? { |p| p.include?(" ") }, "no spaces in any name")
    assert_equal "#{ROOT}.zip", m.filename
    assert_equal "#{ROOT}/README.txt", m.readme_path
  end

  test "prompt.txt is the card's prompt byte for byte, built from the snapshot and current numbers" do
    text = manifest.entries.find { |e| e.path == "#{CLIP3}/prompt.txt" }.source
    assert_equal MusicVideos::ClipPrompts.for(chunk(3), swaps: @swaps), text
    assert_includes text, "- Person B (lead) -> #4 Test Passer Epsilon, Home White (character sheet 1)"

    Appearance.find_by!(slug: @swaps[2].appearance_slug).update!(jersey_number: 12)
    assert_includes manifest.entries.find { |e| e.path == "#{CLIP3}/prompt.txt" }.source, "#12 Test Passer Epsilon",
                    "the number is read at request time, never stored"
  end

  test "lettered frames keep the card's order and carry number, letters and time" do
    frames = manifest.entries.select { |e| e.path.start_with?("#{CLIP3}/frames/") }
    assert_equal ["#{CLIP3}/frames/frame_1_ABC_0045.jpg", "#{CLIP3}/frames/frame_2_ABC_0054.jpg"], frames.map(&:path)
    assert_equal chunk(3).reference_frame_list.map { |f| f["object_key"] }, frames.map(&:source)
    assert(frames.all? { |f| f.kind == :object })
  end

  test "sheets follow the prompt's sheet order, named by number, letter, jersey, person and look" do
    sheets = manifest.entries.select { |e| e.path.start_with?("#{CLIP3}/sheets/") }
    assert_equal ["#{CLIP3}/sheets/sheet_1_B_04_test-passer-epsilon_home-white.png",
                  "#{CLIP3}/sheets/sheet_2_C_88_test-receiver-zeta_home-white.png"], sheets.map(&:path)
    rows = MusicVideos::ClipPrompts.lettered(chunk(3), swaps: @swaps)
    assert_equal rows.map { |r| "sheet_#{r.sheet}_#{r.letter}" }, sheets.map { |s| File.basename(s.path).split("_").first(3).join("_") }
    assert_equal %w[https://assets.mcritchie.studio/sheets/look-0.png https://assets.mcritchie.studio/sheets/look-1.png], sheets.map(&:source)
    assert(sheets.all? { |s| s.kind == :url })
  end

  test "a look without a jersey number drops the number from the name" do
    Appearance.find_by!(slug: @swaps[2].appearance_slug).update!(jersey_number: nil)
    assert_includes paths, "#{CLIP3}/sheets/sheet_1_B_test-passer-epsilon_home-white.png"
  end

  test "a sheet off an https public host, or never built, is not an entry and is listed as missing" do
    Artifact.newest_character_sheets([@swaps[2].appearance_slug]).values.first.update_columns(image_url: "http://127.0.0.1/sheet.png")
    Artifact.newest_character_sheets([@swaps[3].appearance_slug]).values.first.update_columns(retired_at: Time.current)
    m = manifest
    assert(paths(m).none? { |p| p.include?("/sheets/") })
    reasons = m.missing.to_h { |x| [File.basename(x.path), x.reason] }
    assert_match(/not on an https public host/, reasons["sheet_1_B_04_test-passer-epsilon_home-white.png"])
    assert_match(/no character sheet/, reasons["sheet_2_C_88_test-receiver-zeta_home-white.png"])
    assert_includes m.readme, "sheet_1_B_04_test-passer-epsilon_home-white.png  Sheet 1 · Person B · Test Passer Epsilon > Home White: " \
                              "the sheet image is not on an https public host, so it was not fetched."
  end

  # The next engine's guard looks each sheet's host up (/tasks/url-guard-off-hot-paths).
  test "sheets on one host cost one lookup, and a host that could not be looked up says so" do
    with_url_guard do |lookups|
      m = manifest
      assert_operator m.entries.count { |e| e.kind == :url }, :>, 1, "the control: more than one sheet was judged"
      assert_equal %w[assets.mcritchie.studio], lookups
    end

    ActiveSupport::CurrentAttributes.reset_all
    with_url_guard(unresolved: %w[assets.mcritchie.studio]) do
      m = manifest
      assert(paths(m).none? { |p| p.include?("/sheets/") })
      reasons = m.missing.map(&:reason).uniq
      assert_equal 1, reasons.size, reasons.inspect
      assert_match(/could not be looked up/, reasons.first)
      assert_no_match(/not on an https public host/, m.readme)
    end
  end

  test "a clip's zip holds only that clip and names it" do
    m = manifest(only: "3")
    assert_equal "#{ROOT}_clip_03.zip", m.filename
    assert(paths(m).all? { |p| p.start_with?("#{CLIP3}/") })
    assert_includes m.readme, "one clip (Clip 3)"
    assert_raises(ActiveRecord::RecordNotFound) { manifest(only: "99") }
  end

  test "a clip whose window was re-tiled is listed, not fetched" do
    chunk(4).update_columns(start_ms: chunk(4).start_ms + 1000)
    m = manifest
    folder = "#{ROOT}/#{Manifest.clip_folder_name(@alt.clips.find { |c| c.chunk_ordinal == 4 })}"
    assert(paths(m).none? { |p| p.start_with?(folder) })
    assert_match(/re-tiled/, m.missing.find { |x| x.path == "#{folder}/" }.reason)
  end

  test "the README names every letter, who replaces whom, the sheet numbering and what is missing" do
    readme = manifest(page_url: "http://localhost/x").readme([Manifest::Missing.new(path: "#{CLIP3}/source_clip.mp4", label: "Clip 3 source clip",
                                                                                    reason: "not in storage")])
    assert_includes readme, "  A  Person 1 (man in the red coat)  stays as filmed"
    assert_includes readme, "  B  Person 2 (woman in the blue dress)  -> #4 Test Passer Epsilon > Home White"
    assert_includes readme, "  C  Person 3 (man in the green cap)  -> #88 Test Receiver Zeta > Home White"
    assert_includes readme, "    sheet 1  Person B (lead) -> #4 Test Passer Epsilon > Home White  sheets/sheet_1_B_04_test-passer-epsilon_home-white.png"
    assert_includes readme, "    sheet 2  Person C (background) -> #88 Test Receiver Zeta > Home White  sheets/sheet_2_C_88_test-receiver-zeta_home-white.png"
    assert_includes readme, "    frames/frame_1_ABC_0045.jpg  0:45 · A B C"
    assert_includes readme, "#{CLIP3}/source_clip.mp4  Clip 3 source clip: not in storage."
    assert_includes readme, "Page          http://localhost/x"
    assert_includes readme, "Generated versions are not included"
    assert_includes manifest.readme, "Nothing: every file was fetched."
  end

  test "the manifest reads a fixed number of queries whatever the clip count" do
    queries = count_queries { Manifest.for(AltVideo.find(@alt.id)).readme }
    one = count_queries { Manifest.for(AltVideo.find(@alt.id), only: "1").readme }
    assert_operator @alt.clips.size, :>, 1
    assert_equal one, queries, "a clip more reads no more rows"
    assert_operator queries, :<=, 7
  end

  private

  def count_queries(&)
    count = 0
    # Cached hits count too: the test env's query cache would otherwise hide a repeat.
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end
end
