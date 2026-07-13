# frozen_string_literal: true

require "json"

# TaskUsageAudit — a READ-ONLY sweep of the usage/cost baseline store for rows a
# test run left behind. It reports; it never writes, moves, or deletes. Purging a
# row is the operator's call: a baseline is indistinguishable at the file level
# from legitimate operator state, and the deletion is not reversible.
#
# WHY. The baselines under <projects>/.agents/task-usage feed measured $cost,
# which feeds Task#actual_size (bucketed on $cost) and the reviewer-select
# baselines. A test child that resolved the real store (see TaskUsageSandbox for
# the leak that did exactly this) writes a row keyed by its STUB slug and carrying
# the totals of whatever transcript it globbed — in the known case, ~1.9 billion
# cache-read tokens against the fixture slug "demo-task". The sandbox stops new
# rows; this makes the ones already there findable instead of silently priced in.
#
# THE SIGNAL IS THE SLUG, NOT THE SIZE. A stored row is the session's CUMULATIVE
# token totals at the moment it touched that task — the snapshot a later move diffs
# against — NOT that task's spend. So a long real session legitimately banks a
# baseline of a billion cached tokens, and row magnitude is worthless as evidence:
# an earlier cut of this audit flagged "implausible" totals and lit up ~80 real
# rows (reclaim-guard-live-claim at 688M, heartbeat-attribution-and-launchers at
# 1.2B — all genuine). An audit that cries wolf is an audit nobody runs, so it is
# gone. What remains is exact: a row keyed by a slug that only a TEST STUB ever
# serves cannot have come from a real task, whatever its totals.
#
# Plain Ruby (no Rails) so bin/task can require it directly.
module TaskUsageAudit
  # The slugs the CLI test stubs serve — test/lib/task_cli_test.rb answers every
  # board read with "demo-task", test/lib/reviewer_select_test.rb with
  # "cli-board-sample". A baseline keyed by one of these was written by a test
  # child, full stop: no real task has ever carried these slugs.
  FIXTURE_SLUGS = %w[demo-task cli-board-sample].freeze

  # …and the shapes a stub slug takes, to catch the fixtures not yet enumerated.
  FIXTURE_SLUG_PATTERNS = [/\Ademo-/, /\Astub-/, /\Afixture-/, /\Asample-/].freeze

  Row = Struct.new(:path, :session, :slug, :totals, :reasons, keyword_init: true) do
    def cache_read = totals["cache_read"].to_i

    def to_s
      "#{slug}  (session #{session})  cache_read=#{cache_read}  #{reasons.join(', ')}  #{path}"
    end
  end

  module_function

  # Every suspect row in +dir+, newest file first. Unreadable / malformed files are
  # skipped: an audit that raises on a stray file is an audit nobody runs.
  def scan(dir)
    Dir.glob(File.join(dir.to_s, "*.json")).sort.flat_map { |path| rows_in(path) }.compact
  end

  def rows_in(path)
    data = JSON.parse(File.read(path))
    return [] unless data.is_a?(Hash)

    session = File.basename(path, ".json")
    data.filter_map do |slug, totals|
      next unless totals.is_a?(Hash)

      reasons = reasons_for(slug, totals)
      next if reasons.empty?

      Row.new(path: path, session: session, slug: slug, totals: totals, reasons: reasons)
    end
  rescue StandardError
    []
  end

  def reasons_for(slug, _totals)
    fixture_slug?(slug) ? ["fixture-slug"] : []
  end

  def fixture_slug?(slug)
    slug = slug.to_s
    FIXTURE_SLUGS.include?(slug) || FIXTURE_SLUG_PATTERNS.any? { |pattern| slug.match?(pattern) }
  end

  # The human report. Returns [text, suspect_count] so a caller can set an exit code
  # without re-deriving it.
  def report(dir)
    rows = scan(dir)
    return ["task-usage audit: #{dir}\nno suspect rows\n", 0] if rows.empty?

    files = rows.map(&:path).uniq.size
    lines = ["task-usage audit: #{dir}",
             "#{rows.size} test-written row(s) across #{files} session file(s) — READ-ONLY; purging is the operator's call",
             ""]
    rows.group_by(&:slug).sort_by { |slug, group| [-group.size, slug] }.each do |slug, group|
      lines << "  #{slug} — #{group.size} row(s)"
      group.each { |row| lines << "      session #{row.session}  cache_read=#{row.cache_read}" }
    end
    lines << ""
    lines << "Each row is keyed by a slug only a TEST STUB serves, so it was written by a test child,"
    lines << "not by real work. Removing one means editing that key out of the session's JSON — the"
    lines << "operator's call, never this tool's."
    ["#{lines.join("\n")}\n", rows.size]
  end
end
