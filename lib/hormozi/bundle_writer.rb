# frozen_string_literal: true

require "json"
require "fileutils"

module Hormozi
  # Writes one JSON file per bundle plus the index the synthesis wave reads, and
  # owns the ONE destructive step in the whole corpus pipeline: clearing the
  # previous bundles directory.
  #
  # WHY THIS IS A LIBRARY AND NOT FOUR LINES IN bin/hormozi-bundle. The order of
  # "decide" and "destroy" is the entire safety property here, and an ordering is
  # only provable where a test can drive it. Inline in the script it was wrong:
  # the rm_rf ran BEFORE the --min-sources filter and mkdir_p happened only
  # per-bundle inside the write loop, so a filter that selected nothing deleted
  # every bundle, skipped the loop, never recreated the directory, and died
  # Errno::ENOENT writing the index into the directory it had just removed.
  #
  # WHY A --min-sources THAT SELECTS NOTHING IS ORDINARY, not operator error. The
  # distribution is long-tailed and its top MOVES as the extraction wave adds
  # files: measured 2026-09-20 over 12 extraction files, 1305 ideas had 1 source,
  # 25 had 2, one had 3 and two had 4. So the smallest value that selects nothing
  # was 5 that day and was lower the week before. No safe constant exists to
  # document, which is exactly why the RUN has to be safe.
  #
  # THE RULE, which is the backend discipline rule (validate before irreversible
  # side effects): destruction follows the decision, and nothing irreversible
  # happens on a run that produced nothing to put back. An empty selection is a
  # legitimate ANSWER to a --min-sources question, not an instruction to throw
  # the previous run's output away — so it writes the empty index and leaves the
  # existing bundles where they are.
  module BundleWriter
    INDEX = "index.tsv"
    HEADER = %w[kind slug sources items name].freeze

    # Writes `bundles` into `bundles_dir` and returns the index path.
    #
    # A non-empty selection is a full REBUILD: the directory is cleared first, so
    # a bundle the previous run wrote and this one no longer produces disappears
    # rather than lingering unreferenced by the index.
    def self.write(bundles_dir, bundles)
      FileUtils.rm_rf(bundles_dir) if bundles.any?
      FileUtils.mkdir_p(bundles_dir)

      rows = bundles.map do |bundle|
        dir = File.join(bundles_dir, bundle.kind)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{bundle.slug}.json"), JSON.pretty_generate(payload_for(bundle)))
        [ bundle.kind, bundle.slug, bundle.source_count, bundle.item_count, bundle.name ]
      end

      index_path = File.join(bundles_dir, INDEX)
      File.write(index_path, ([ HEADER.join("\t") ] + rows.map { |row| row.join("\t") }).join("\n") + "\n")
      index_path
    end

    def self.payload_for(bundle)
      {
        kind: bundle.kind,
        name: bundle.name,
        slug: bundle.slug,
        source_count: bundle.source_count,
        sources: bundle.sources,
        items: bundle.items
      }
    end

    # How many bundle files the directory holds right now. The caller needs this
    # to say, in the empty-selection warning, what it declined to delete — a
    # warning the operator cannot size is a warning they cannot act on.
    def self.bundle_file_count(bundles_dir)
      Dir.glob(File.join(bundles_dir, "*", "*.json")).length
    end
  end
end
