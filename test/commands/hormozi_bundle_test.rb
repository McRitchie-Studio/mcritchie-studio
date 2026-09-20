# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# [integration] THE BUNDLE RUN IS THE ONLY DESTRUCTIVE STEP IN THE CORPUS
# PIPELINE — it deletes and rebuilds bundles/ — so it is exercised end to end:
# real files, real process, real exit status, and the directory inspected AFTER.
#
# THE DEFECT THIS HOLDS SHUT. The rm_rf ran BEFORE the --min-sources filter, and
# mkdir_p happened only per-bundle inside the write loop. So a filter that
# selected NOTHING deleted every existing bundle, never entered the loop, never
# recreated the directory, and then died Errno::ENOENT writing index.tsv into the
# directory it had just removed. The bundles were gone by then.
#
# WHY IT WAS REACHABLE AND NOT THEORETICAL. The source distribution is long-tailed
# and its top MOVES as the extraction wave adds files — measured 2026-09-20 over 12
# extraction files, 1305 ideas had 1 source, 25 had 2, one had 3, two had 4 — so the
# smallest --min-sources that selects nothing is a number nobody can know in
# advance, and it was 5 that day. The data is rebuildable from extract/*.json and
# the failure was loud, which is why this was a filed bug and not an incident; it
# was still a half-applied destructive operation.
#
# THE RULE IT PINS: destruction follows the decision. An empty selection is a
# legitimate ANSWER to a --min-sources question, not an instruction to throw the
# previous run's output away.
class HormoziBundleTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/hormozi-bundle", __dir__)

  # Two ideas, one source each — so any --min-sources above 1 selects nothing,
  # exactly as the live corpus behaves against the documented example.
  EXTRACTION = {
    "items" => [
      { "kind" => "framework", "name" => "Rule of 100", "claim" => "do a hundred a day", "source_id" => "v1" },
      { "kind" => "play", "name" => "Give Away The Secret", "claim" => "sell the implementation", "source_id" => "v1" }
    ]
  }.freeze

  def test_a_selection_that_matches_nothing_writes_the_index_and_deletes_nothing
    with_corpus do |root|
      survivor = File.join(root, "bundles", "framework", "already-here.json")
      FileUtils.mkdir_p(File.dirname(survivor))
      File.write(survivor, JSON.generate(kind: "framework", name: "Already Here"))

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root, "--min-sources", "3")

      assert status.success?, "an empty selection is an answer, not a crash: #{out}"
      assert File.exist?(survivor), "THE BUG: every existing bundle was deleted before the filter ran"
      assert_equal "Already Here", JSON.parse(File.read(survivor))["name"], "the survivor must be intact, not re-created empty"

      index = File.readlines(File.join(root, "bundles", "index.tsv"), chomp: true)
      assert_equal %w[kind slug sources items name].join("\t"), index.first
      assert_equal 1, index.length, "an empty selection writes a header and no rows"
      assert_match(/--min-sources 3/, out, "the operator must be told why the index came back empty")
    end
  end

  # The normal path must still be a clean REBUILD, not an accumulation: a bundle
  # the previous run wrote and this one no longer produces has to disappear.
  def test_a_selection_that_matches_rebuilds_the_directory_from_scratch
    with_corpus do |root|
      stale = File.join(root, "bundles", "framework", "no-longer-extracted.json")
      FileUtils.mkdir_p(File.dirname(stale))
      File.write(stale, "{}")

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      assert status.success?, "bundle failed: #{out}"
      refute File.exist?(stale), "a rebuild must clear what the previous run left behind"
      assert File.exist?(File.join(root, "bundles", "framework", "rule-of-100.json"))
      assert File.exist?(File.join(root, "bundles", "play", "give-away-the-secret.json"))

      index = File.readlines(File.join(root, "bundles", "index.tsv"), chomp: true)
      assert_equal 3, index.length, "header plus one row per bundle"
      assert_match(/2 bundle\(s\)/, out)
    end
  end

  def test_refuses_a_root_with_no_extraction_files_before_touching_bundles
    with_corpus do |root|
      FileUtils.rm_rf(File.join(root, "extract"))
      FileUtils.mkdir_p(File.join(root, "bundles"))
      keeper = File.join(root, "bundles", "index.tsv")
      File.write(keeper, "kept\n")

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, "--root", root)

      refute status.success?
      assert_match(/no extraction files/, out)
      assert_equal "kept\n", File.read(keeper), "it must refuse BEFORE deleting"
    end
  end

  def with_corpus
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "extract"))
      File.write(File.join(root, "extract", "batch-1.json"), JSON.generate(EXTRACTION))
      yield root
    end
  end
end
