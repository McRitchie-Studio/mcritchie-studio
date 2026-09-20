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

  def test_refuses_a_root_with_no_captions
    Dir.mktmpdir do |root|
      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      refute status.success?
      assert_match(/no captions/, out)
    end
  end
end
