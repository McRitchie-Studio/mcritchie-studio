# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

# [integration] THE PREP RUN IS THE ONLY THING STANDING BETWEEN 1,700 CAPTION
# FILES AND AN EXTRACTION WAVE, SO IT IS EXERCISED END TO END — real files, real
# process, real exit status.
#
# TWO DEFECTS THIS HOLDS SHUT.
#
# 1. THE SEPARATOR. The yt-dlp listing was dumped through a shell that turned
#    `\t` into the two characters backslash-t rather than a tab. Splitting on a
#    real tab alone reads the entire line as the video id, every title comes
#    back nil, every episode scores zero, and the manifest tiers the whole
#    corpus at 3 — a total triage failure that still exits 0 and still prints a
#    cheerful summary. The fixture below deliberately uses the broken form.
#
# 2. RE-CLEANING. The wave reruns after a partial caption fetch. A prep that
#    re-cleans everything each time turns a 30-second resume into a full pass,
#    so an existing transcript must be reused unless --force says otherwise.
#
# TWO MORE, FOUND IN THE PR 1467 REVIEW AND PINNED BELOW.
#
# 3. THE TRUNCATED TRANSCRIPT. Reuse asked File.exist? — existence, not
#    completeness — and the write it paired that with was a plain File.write.
#    A prep interrupted mid-write during a 516-file clean therefore left a
#    zero-byte .txt that satisfied every later run FOREVER: reused at exit 0,
#    counted in the cheerful summary, and read as an empty transcript by the
#    extraction wave for a tier-1 episode. Silent and permanent.
#
# 4. THE REGION-CODED CAPTION. The video id was derived with a lowercase-only
#    language-tag class, so a `<id>.en-US.vtt` kept its tag: the metadata lookup
#    missed, the title fell back to the filename, and a real episode tiered at 3
#    at exit 0. Reachable the moment the fetch widens its --sub-langs.
class HormoziPrepTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/hormozi-prep", __dir__)

  VTT = <<~VTT
    WEBVTT
    Kind: captions

    00:00:01.000 --> 00:00:02.000 align:start position:0%
    your offer is the business
    and<00:00:01.400><c> the</c><00:00:01.600><c> ads</c>

    00:00:02.000 --> 00:00:03.000 align:start position:0%
    and the ads are the leads
  VTT

  def test_cleans_tiers_and_is_idempotent_on_a_rerun
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "captions"))
      Dir.mkdir(File.join(root, "meta"))
      File.write(File.join(root, "captions", "P14HA83uNJE.en.vtt"), VTT)
      # The literal backslash-t the real dump produced, not a tab.
      File.write(
        File.join(root, "meta", "channel_videos.tsv"),
        "P14HA83uNJE\\t531\\tHow To Write Ads That Get Leads\n"
      )

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      assert status.success?, "prep failed: #{out}"
      assert_match(/cleaned 1, reused 0/, out)

      transcript = File.read(File.join(root, "transcripts", "P14HA83uNJE.txt"))
      assert_equal "your offer is the business and the ads are the leads", transcript

      manifest = File.readlines(File.join(root, "extract", "manifest.tsv"), chomp: true)
      assert_equal %w[id tier score duration_s words title].join("\t"), manifest.first

      id, tier, _score, duration, words, title = manifest[1].split("\t")
      assert_equal "P14HA83uNJE", id
      assert_equal "1", tier, "a title naming ads and leads must reach tier 1"
      assert_equal "531", duration, "the duration column proves the metadata separator parsed"
      assert_equal "11", words
      assert_equal "How To Write Ads That Get Leads", title

      rerun, rerun_status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)
      assert rerun_status.success?
      assert_match(/cleaned 0, reused 1/, rerun)
    end
  end

  # An unknown FLAG is OptionParser's problem and it raises. A leftover POSITIONAL
  # is nobody's problem unless the script makes it one — and this script rewrites
  # every transcript under a root, so ignoring the path someone typed means
  # re-cleaning the default corpus while they watch the wrong directory.
  def test_refuses_a_leftover_positional_argument
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "captions"))

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root, "./captions")

      refute status.success?
      assert_match(/unexpected argument/, out)
      refute File.exist?(File.join(root, "extract", "manifest.tsv")), "it must refuse BEFORE writing"
    end
  end

  # A zero-byte transcript is what an interrupted write leaves behind, and the
  # only thing separating it from a finished one is its size. Reused, it reports a
  # tier-1 episode with 0 words at exit 0 — the extraction wave then reads
  # nothing and nobody is told.
  def test_re_cleans_a_truncated_transcript_instead_of_reusing_it
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "captions"))
      Dir.mkdir(File.join(root, "meta"))
      Dir.mkdir(File.join(root, "transcripts"))
      File.write(File.join(root, "captions", "P14HA83uNJE.en.vtt"), VTT)
      File.write(
        File.join(root, "meta", "channel_videos.tsv"),
        "P14HA83uNJE\\t531\\tHow To Write Ads That Get Leads\n"
      )
      transcript_path = File.join(root, "transcripts", "P14HA83uNJE.txt")
      File.write(transcript_path, "")

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      assert status.success?, "prep failed: #{out}"
      assert_match(/cleaned 1, reused 0/, out, "THE BUG: an empty transcript satisfied the existence check")
      assert_equal "your offer is the business and the ads are the leads", File.read(transcript_path)

      _id, _tier, _score, _duration, words, = File.readlines(File.join(root, "extract", "manifest.tsv"), chomp: true)[1].split("\t")
      assert_equal "11", words, "the manifest reported 0 words for a tier-1 episode and exited 0"
    end
  end

  # Interruption is the trigger, so the write must land by rename: either the old
  # transcript or the whole new one is on disk, never a prefix of it, and no
  # staging file is left where a later run could mistake it for output.
  def test_a_completed_write_leaves_no_staging_file_behind
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "captions"))
      File.write(File.join(root, "captions", "P14HA83uNJE.en.vtt"), VTT)

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      assert status.success?, "prep failed: #{out}"
      assert_equal [ "P14HA83uNJE.txt" ], Dir.children(File.join(root, "transcripts")).sort
    end
  end

  # yt-dlp names the file after whatever --sub-langs asked for, and a region-coded
  # tag is capitalized. Stripping only lowercase left the tag ON the id.
  def test_derives_the_video_id_from_a_region_coded_caption_name
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "captions"))
      Dir.mkdir(File.join(root, "meta"))
      File.write(File.join(root, "captions", "P14HA83uNJE.en-US.vtt"), VTT)
      File.write(
        File.join(root, "meta", "channel_videos.tsv"),
        "P14HA83uNJE\\t531\\tHow To Write Ads That Get Leads\n"
      )

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      assert status.success?, "prep failed: #{out}"
      assert File.exist?(File.join(root, "transcripts", "P14HA83uNJE.txt")), "THE BUG: the transcript was named P14HA83uNJE.en-US.txt"

      id, tier, _score, duration, _words, title = File.readlines(File.join(root, "extract", "manifest.tsv"), chomp: true)[1].split("\t")
      assert_equal "P14HA83uNJE", id
      assert_equal "531", duration, "a mis-derived id misses the metadata row entirely"
      assert_equal "How To Write Ads That Get Leads", title
      assert_equal "1", tier, "and a missed title tiers a real episode at 3"
    end
  end

  def test_refuses_a_root_with_no_captions
    Dir.mktmpdir do |root|
      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      refute status.success?
      assert_match(/no captions/, out)
    end
  end
end
