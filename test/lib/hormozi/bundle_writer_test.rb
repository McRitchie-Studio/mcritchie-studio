# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/hormozi/bundle_writer"
require_relative "../../../lib/hormozi/bundler"

# [unit] THE ORDER OF "DECIDE" AND "DESTROY" IS THE WHOLE SAFETY PROPERTY. Clearing bundles/
# must not run before the --min-sources filter: an empty selection would delete every bundle,
# skip the write loop, and die Errno::ENOENT writing the index.
# The smallest --min-sources that selects nothing is not a constant: the source distribution is
# long-tailed and its top climbs.
# BOTH DIRECTIONS ARE PINNED: an empty selection destroys NOTHING, and a real selection is a
# full REBUILD, not an accumulation.
# History: task harden-hormozi-corpus-scripts.
class BundleWriterTest < Minitest::Test
  def test_an_empty_selection_writes_the_index_and_deletes_nothing
    Dir.mktmpdir do |dir|
      bundles_dir = File.join(dir, "bundles")
      survivor = File.join(bundles_dir, "framework", "rule-of-100.json")
      FileUtils.mkdir_p(File.dirname(survivor))
      File.write(survivor, JSON.generate(name: "Rule of 100"))

      index_path = Hormozi::BundleWriter.write(bundles_dir, [])

      assert File.exist?(survivor), "THE BUG: the directory was cleared before anything decided to clear it"
      assert_equal "Rule of 100", JSON.parse(File.read(survivor))["name"]
      assert_equal [ %w[kind slug sources items name].join("\t") ], File.readlines(index_path, chomp: true)
    end
  end

  # The crash was the loud half. The quiet half is that the deletion had already
  # happened, so "it raises" is not the property — "the files are still there" is.
  def test_an_empty_selection_into_a_directory_that_does_not_exist_still_writes_an_index
    Dir.mktmpdir do |dir|
      bundles_dir = File.join(dir, "bundles")

      index_path = Hormozi::BundleWriter.write(bundles_dir, [])

      assert File.exist?(index_path), "a first run with no selection must not raise Errno::ENOENT"
      assert_equal 0, Hormozi::BundleWriter.bundle_file_count(bundles_dir)
    end
  end

  def test_a_real_selection_clears_what_the_previous_run_left_behind
    Dir.mktmpdir do |dir|
      bundles_dir = File.join(dir, "bundles")
      stale = File.join(bundles_dir, "framework", "no-longer-extracted.json")
      FileUtils.mkdir_p(File.dirname(stale))
      File.write(stale, "{}")

      Hormozi::BundleWriter.write(bundles_dir, [ bundle(kind: "framework", slug: "rule-of-100", name: "Rule of 100") ])

      refute File.exist?(stale), "an unreferenced bundle must not survive a rebuild"
      assert_equal 1, Hormozi::BundleWriter.bundle_file_count(bundles_dir)
    end
  end

  def test_writes_one_file_per_bundle_and_one_index_row_per_bundle
    Dir.mktmpdir do |dir|
      bundles_dir = File.join(dir, "bundles")

      index_path = Hormozi::BundleWriter.write(bundles_dir, [
        bundle(kind: "framework", slug: "rule-of-100", name: "Rule of 100", sources: %w[v1 v2]),
        bundle(kind: "play", slug: "give-away-the-secret", name: "Give Away The Secret")
      ])

      payload = JSON.parse(File.read(File.join(bundles_dir, "framework", "rule-of-100.json")))
      assert_equal "Rule of 100", payload["name"]
      assert_equal 2, payload["source_count"]
      assert_equal %w[v1 v2], payload["sources"]

      rows = File.readlines(index_path, chomp: true)
      assert_equal 3, rows.length, "header plus one row per bundle"
      assert_equal [ "framework", "rule-of-100", "2", "1", "Rule of 100" ], rows[1].split("\t")
    end
  end

  # Counts BUNDLE files, not everything under the directory — index.tsv is not a
  # bundle, and a warning that counts it lies about what it declined to delete.
  def test_bundle_file_count_ignores_the_index
    Dir.mktmpdir do |dir|
      bundles_dir = File.join(dir, "bundles")
      Hormozi::BundleWriter.write(bundles_dir, [ bundle(kind: "play", slug: "one", name: "One") ])

      assert File.exist?(File.join(bundles_dir, "index.tsv"))
      assert_equal 1, Hormozi::BundleWriter.bundle_file_count(bundles_dir)
    end
  end

  def bundle(kind:, slug:, name:, sources: %w[v1])
    Hormozi::Bundler::Bundle.new(
      kind: kind,
      name: name,
      slug: slug,
      items: [ { "kind" => kind, "name" => name, "claim" => "a claim", "source_id" => sources.first } ],
      sources: sources
    )
  end
end
