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
#
# THE GATE KEEPS THE SOURCE SCAN, ON PURPOSE. Playwright's own `--list` counts a `test(`
# written in a loop correctly, where this scan counts one, but `--list` is the RUNNER'S
# view: it honours `.only`, `testIgnore` and a narrowed `testDir`, the very ways a lane
# shrinks that the census exists to see past. So `--list` (listed) is the pre-flight's
# cross-check (bin/e2e-census-check, run by bin/fast-check): where it disagrees with
# the scan, the gate will go red on CI, and the author hears it in a minute instead.
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

  # Playwright's summary line under `--list`: "Total: 267 tests in 107 files".
  LIST_TOTAL = /^Total: (?<tests>\d+) tests? in (?<files>\d+) files?$/

  # The Playwright runner for `root`: node_modules/.bin/playwright in `root` or the
  # nearest directory above it (a desk under .worktrees/ resolves the hub's, as
  # Node's own resolution does). nil when none is installed.
  def playwright_bin(root)
    dir = File.expand_path(root)
    loop do
      candidate = File.join(dir, "node_modules", ".bin", "playwright")
      return candidate if File.executable?(candidate)

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  # The census as Playwright lists it, or [nil, reason] when it cannot be listed.
  # `runner` takes an argv and a chdir and returns [output, success]; it defaults to
  # running Playwright itself. Listing loads the config and the spec files, and
  # starts no web server and no browser.
  def listed(root, quarantine_tag:, bin: playwright_bin(root), runner: method(:run_list))
    return [nil, "Playwright is not installed in or above #{root} (npm ci)"] unless bin

    lane, lane_ok = runner.call([bin, "test", "--list", "--grep-invert", quarantine_tag], root)
    lane_total = lane.to_s.match(LIST_TOTAL)
    return [nil, "`playwright test --list` did not list the suite: #{lane.to_s.lines.last(3).join.strip}"] unless lane_ok && lane_total

    # No quarantined spec left reads "No tests found" with no Total line: zero.
    held, = runner.call([bin, "test", "--list", "--grep", quarantine_tag], root)
    held_total = held.to_s.match(LIST_TOTAL)
    executed = lane_total[:tests].to_i
    quarantined = held_total ? held_total[:tests].to_i : 0
    [Census.new(total: executed + quarantined, quarantined: quarantined, lane_files: lane_total[:files].to_i), nil]
  end

  def run_list(argv, root)
    require "open3"
    out, status = Open3.capture2e(*argv, chdir: root)
    [out, status.success?]
  rescue SystemCallError => e
    ["#{e.class}: #{e.message}", false]
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
