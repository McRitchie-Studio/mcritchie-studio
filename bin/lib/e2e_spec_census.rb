# frozen_string_literal: true

# bin/lib/e2e_spec_census.rb — THE SPEC COUNT, computed from the committed e2e/ suite.
#
# The e2e lane's arithmetic is `executed == committed - quarantined`. Both sides of it
# used to be hand-written counts in config/e2e_lane.yml that every spec add had to bump.
# They are computed here instead, from the spec files, so adding a spec moves nothing by
# hand. Both halves of the lane's guard read this one census:
#
#   · bin/e2e-executed-set-check              the runtime gate: Playwright's own report
#                                             must show `executed` specs ran
#   · test/lib/e2e_quarantine_ratchet_test.rb the static guard: every committed spec is a
#                                             bare declaration, so the census is honest
#
# Only `quarantined` stays hand-written (in config/e2e_lane.yml), because it is a ceiling
# ratcheted against origin/release: the tagged count must equal it, and it may not rise.
#
# A SPEC is a bare `test(` / `it(` call with a title. The static guard refuses every
# modifier that could change which specs run, so a bare declaration is the whole set.
module E2eSpecCensus
  SPEC_DECLARATION = /^\s*(?:test|it)\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  Census = Struct.new(:total, :quarantined, :lane_files, keyword_init: true) do
    def executed = total - quarantined
  end

  module_function

  # Comments are not code: `// test("x")` declares nothing.
  def strip_comments(source)
    source.gsub(%r{/\*.*?\*/}m, "").gsub(%r{//[^\n]*}, "")
  end

  def spec_titles(source)
    strip_comments(source).lines.filter_map { |line| line.match(SPEC_DECLARATION)&.[](:title) }
  end

  def spec_files(e2e_dir)
    Dir.glob(File.join(e2e_dir, "**", "*.spec.js")).sort
  end

  # The census of `e2e_dir`: every bare spec, those carrying `quarantine_tag` in their
  # title, and the files that carry at least one spec the lane runs (Playwright keeps a
  # file's specs on one shard, so that count floors the shards).
  def count(e2e_dir, quarantine_tag:)
    titles = spec_files(e2e_dir).map { |path| spec_titles(File.read(path)) }
    Census.new(
      total: titles.sum(&:size),
      quarantined: titles.sum { |file| file.count { |title| title.include?(quarantine_tag) } },
      lane_files: titles.count { |file| file.any? { |title| !title.include?(quarantine_tag) } }
    )
  end
end
