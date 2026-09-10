# frozen_string_literal: true

require "test_helper"

# [docs] THE DEPENDENCY DECISION RECORD, HELD AGAINST ITSELF AND AGAINST .github/
#
#   ruby -Itest test/docs/dependency_decisions_docs_test.rb
# Also picked up by the normal `bin/rails test` sweep. NOT by `bin/fast-check`,
# which does not map test/docs — a green fast-check is no evidence this ran.
#
# WHAT THIS GUARDS. docs/agents/maintenance/dependency-decisions.md records a
# disposition per open Dependabot PR, grouped by cause. It is a snapshot, and the
# defect it exists to prevent is a snapshot that goes on reading as freshly
# measured after it stopped being true. The measurement that produced it moved
# TWICE while it was being written: a 2026-09-09 21:00Z pass recorded 12 RED / 15
# GREEN, and a re-measure the next morning found 4 RED / 23 GREEN on the same 27
# PRs. A stale count is not a cosmetic problem here — the earlier pass's red list
# was the input to "which of these do we act on", and eight of its twelve reds had
# already resolved.
#
# ── THE LIMIT, STATED PLAINLY ────────────────────────────────────────────────
#
# No test in this suite can re-measure GitHub. CI has no business calling
# `gh pr list`, and a guard that did would be flaky, slow, and would fail for
# reasons that have nothing to do with the diff under test. So this guard CANNOT
# notice that a PR in the table was merged, closed, or rebased. The doc says so in
# its own closing section, and the re-measure commands are printed at its top.
#
# What this guard CAN do is two things, and it does both:
#
#   1. INTERNAL CONSISTENCY. The tally line, the per-repo tally table and the
#      section headers are recomputed from the rows (counts in running prose are
#      NOT — review caught five that had drifted). A hand-edit that
#      changes rows without changing the tally — the single most likely way this
#      document rots — fails here. Cause ids are cross-referenced in BOTH
#      directions, so neither an orphan cause nor a row pointing at a cause that
#      was deleted survives. Every row typed MAJOR must carry a migration-cost
#      sentence, which is the acceptance criterion that is easiest to drop when
#      adding a row in a hurry.
#
#   2. TRIPWIRES ON THE RECORD'S OWN ADVICE. The record makes two claims about
#      files that live IN THIS REPO, and each claim is the premise of a
#      recommendation: `.github/dependabot.yml` carries no `ignore` block
#      (CONFIG-3, the premise of "close and add ignore entries"), and the Gemfile
#      still pins minitest and redis (CAUSE-A, the premise of those closes). No
#      tripwire pins an action version: Dependabot is what bumps those, and a bot
#      PR cannot refresh this record, so it would only redden a correct bump.
#      ACTING ON THE ADVICE TURNS THIS TEST
#      RED. That is the point, and it is why these are asserted rather than merely
#      described: the moment someone adds the ignore entries or lifts a pin, the
#      record's reasoning is spent and CI says so instead of letting the paragraph
#      sit there arguing for work already done.
#
# Anchoring the tripwires on the real files rather than on a restated list is what
# keeps them honest. A table of expected values inside this test would need its own
# guard, and would pass just as happily over a record that no longer matches the
# repo.
class DependencyDecisionsDocsTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs", "agents", "maintenance", "dependency-decisions.md")

  DISPOSITIONS = %w[MERGE CLOSE HOLD].freeze
  CI_CLASSES = %w[RED FRESH-GREEN STALE-GREEN].freeze
  SEVERITIES = %w[MAJOR minor patch].freeze

  # One parsed row of the per-repo disposition tables.
  Row = Struct.new(:repo, :pr, :package, :severity, :ci, :behind, :cause, :disposition)

  def self.doc_body
    @doc_body ||= File.read(DOC)
  end

  # Slice a "## Heading" section out of the document, exclusive of the next
  # heading at the same level.
  def section(title, level: "##")
    body = self.class.doc_body
    start = body.index(/^#{Regexp.escape(level)} #{Regexp.escape(title)}\s*$/)
    refute_nil start, "dependency-decisions.md is missing the `#{level} #{title}` section"
    rest = body[start..]
    stop = rest.index(/^#{Regexp.escape(level)} /, 1)
    stop ? rest[0...stop] : rest
  end

  def table_cells(line)
    line.strip.sub(/\A\|/, "").sub(/\|\z/, "").split("|").map(&:strip)
  end

  # Every `| #123 | … |` row in the three per-repo tables, tagged with its repo.
  def rows
    @rows ||= begin
      body = section("The table")
      current = nil
      out = []
      body.each_line do |line|
        if (m = line.match(/^### (\S+) — (\d+) open\s*$/))
          current = m[1]
          next
        end
        next unless current && line.start_with?("| #")

        cells = table_cells(line)
        assert_equal 8, cells.length,
                     "row `#{line.strip}` under #{current} does not have the 8 columns the table declares"
        out << Row.new(current, cells[0], cells[1], cells[3], cells[4], cells[5], cells[6], cells[7])
      end
      out
    end
  end

  def ci_class_of(row)
    row.ci.split(/[\s(]/).first
  end

  test "the record exists and stamps when it was measured" do
    assert_path_exists DOC

    body = self.class.doc_body
    assert_match(/^\*\*Measured: (\d{4}-\d{2}-\d{2}) [\d:–\-]+Z\*\*/, body,
                 "the record must open with a parseable `**Measured: YYYY-MM-DD HH:MM–HH:MMZ**` stamp; " \
                 "without it a reader cannot tell a fresh record from a year-old one")

    # The re-measure recipe is the only thing standing between this snapshot and a
    # reader who trusts it blindly. It is load-bearing prose.
    recipe = section("How to re-measure")
    %w[gh\ pr\ list gh\ pr\ view compare/accepted actions/jobs actions/runs].each do |fragment|
      assert_includes recipe, fragment,
                      "the re-measure section must name the `#{fragment}` command; a record with no " \
                      "reproduction path cannot be checked by the next reader"
    end
  end

  test "every row carries a disposition and a CI class from the closed vocabulary" do
    refute_empty rows, "no disposition rows parsed out of `## The table` — the parser or the table shape drifted"

    rows.each do |row|
      assert_includes DISPOSITIONS, row.disposition,
                      "#{row.repo} #{row.pr}: disposition `#{row.disposition}` is not one of #{DISPOSITIONS.join(', ')}. " \
                      "A row without a recognised verdict is an untriaged PR wearing a triaged row."
      assert_includes CI_CLASSES, ci_class_of(row),
                      "#{row.repo} #{row.pr}: CI class `#{ci_class_of(row)}` is not one of #{CI_CLASSES.join(', ')}"
      assert_includes SEVERITIES, row.severity,
                      "#{row.repo} #{row.pr}: severity `#{row.severity}` is not one of #{SEVERITIES.join(', ')}"
      assert_match(/\A\d+\z/, row.behind,
                   "#{row.repo} #{row.pr}: `behind` must be a commit count — base drift is how a stale green is spotted")
    end
  end

  test "no PR is listed twice" do
    rows.group_by(&:repo).each do |repo, repo_rows|
      prs = repo_rows.map(&:pr)
      assert_equal prs.uniq.length, prs.length,
                   "#{repo} lists a PR twice: #{prs.tally.select { |_, n| n > 1 }.keys.join(', ')}"
    end
  end

  test "the stated tally is recomputed from the rows" do
    stated = self.class.doc_body[/^\*\*(\d+) open · (\d+) RED · (\d+) FRESH-GREEN · (\d+) STALE-GREEN\*\*/]
    refute_nil stated, "the `## Tally` section must state `**N open · N RED · N FRESH-GREEN · N STALE-GREEN**`"

    open_count, red, fresh, stale = Regexp.last_match.captures.map(&:to_i)
    counts = rows.group_by { |r| ci_class_of(r) }.transform_values(&:length)

    assert_equal rows.length, open_count,
                 "the tally claims #{open_count} open PRs but the tables carry #{rows.length} rows — " \
                 "someone edited one without the other"
    assert_equal counts.fetch("RED", 0), red, "tally RED disagrees with the rows"
    assert_equal counts.fetch("FRESH-GREEN", 0), fresh, "tally FRESH-GREEN disagrees with the rows"
    assert_equal counts.fetch("STALE-GREEN", 0), stale, "tally STALE-GREEN disagrees with the rows"
  end

  test "the per-repo tally table and the per-repo section headers agree with the rows" do
    by_repo = rows.group_by(&:repo)

    # `| mcritchie-studio | 13 | 1 | 0 | 12 |`
    section("Tally").each_line do |line|
      cells = table_cells(line)
      next unless cells.length == 5 && by_repo.key?(cells[0])

      repo_rows = by_repo.fetch(cells[0])
      counts = repo_rows.group_by { |r| ci_class_of(r) }.transform_values(&:length)
      assert_equal repo_rows.length, cells[1].to_i, "tally table: #{cells[0]} open count disagrees with its rows"
      assert_equal counts.fetch("RED", 0), cells[2].to_i, "tally table: #{cells[0]} RED disagrees with its rows"
      assert_equal counts.fetch("FRESH-GREEN", 0), cells[3].to_i, "tally table: #{cells[0]} fresh-green disagrees"
      assert_equal counts.fetch("STALE-GREEN", 0), cells[4].to_i, "tally table: #{cells[0]} stale-green disagrees"
    end

    section("The table").scan(/^### (\S+) — (\d+) open\s*$/).each do |repo, declared|
      assert_equal by_repo.fetch(repo, []).length, declared.to_i,
                   "the `### #{repo} — #{declared} open` header disagrees with the number of rows beneath it"
    end
  end

  test "cause ids cross-reference in both directions" do
    defined_causes = self.class.doc_body.scan(/^### (CAUSE-[A-Z]) · /).flatten.to_set
    referenced = rows.map(&:cause).to_set

    refute_empty defined_causes, "the record defines no `### CAUSE-X · …` sections"

    (referenced - defined_causes).each do |cause|
      flunk "rows reference #{cause} but no `### #{cause} · …` section defines it"
    end
    (defined_causes - referenced).each do |cause|
      flunk "`### #{cause} · …` is defined but no row is grouped under it — an orphan cause is a cause " \
            "whose PRs were disposed of elsewhere, which is exactly the drift this record exists to prevent"
    end
  end

  test "every MAJOR carries a migration cost, and the migration table invents nothing" do
    majors = rows.select { |r| r.severity == "MAJOR" }.map(&:pr).to_set
    refute_empty majors, "no MAJOR rows parsed — the severity column drifted"

    costed = Set.new
    section("Migration cost — one sentence per major").each_line do |line|
      cells = table_cells(line)
      next unless cells.length == 3 && cells[0].start_with?("#")

      prs = cells[0].scan(/#\d+/)
      refute_empty prs, "migration row `#{line.strip}` names no PR"
      assert_operator cells[2].split.length, :>=, 8,
                      "migration cost for #{prs.join(', ')} is too short to be a real sentence: #{cells[2].inspect}"
      costed.merge(prs)
    end

    (majors - costed).each do |pr|
      flunk "#{pr} is typed MAJOR but has no migration-cost sentence — the record's whole value over a PR " \
            "list is that a major says what taking it would cost"
    end
    (costed - majors).each do |pr|
      flunk "#{pr} has a migration-cost sentence but is not a MAJOR row in any table"
    end
  end

  # ── Tripwires ───────────────────────────────────────────────────────────────
  # These assert the repo-local premises the record's recommendations rest on.
  # They are DESIGNED to fail when the advice is followed.

  test "CONFIG-2 and CONFIG-3 still describe .github/dependabot.yml" do
    config = Rails.root.join(".github", "dependabot.yml").read

    assert_equal 2, config.scan(/^\s*open-pull-requests-limit: 10\s*$/).length,
                 "CONFIG-2 states both ecosystems cap at 10 open PRs. dependabot.yml no longer says that — " \
                 "refresh the `### CONFIG-2` section of docs/agents/maintenance/dependency-decisions.md"

    refute_match(/^\s*ignore:\s*$/, config,
                 "dependabot.yml now carries an `ignore:` block. That is the fix CONFIG-3 and CAUSE-A " \
                 "recommend — so the record's argument for it is now spent. Refresh `### CONFIG-3` and " \
                 "`### CAUSE-A` in docs/agents/maintenance/dependency-decisions.md, and re-check whether the " \
                 "minitest and redis PRs are still open.")
  end

  test "CAUSE-A still describes the Gemfile pins it argues from" do
    gemfile = Rails.root.join("Gemfile").read

    {
      'gem "minitest", "~> 5.25"' => "minitest",
      'gem "redis", "~> 5.4"' => "redis"
    }.each do |declaration, gem_name|
      assert_includes gemfile, declaration,
                      "CAUSE-A quotes `#{declaration}` as the deliberate pin that makes the #{gem_name} " \
                      "Dependabot PRs a CLOSE. The Gemfile no longer carries it, so that verdict no longer " \
                      "follows — refresh `### CAUSE-A` in docs/agents/maintenance/dependency-decisions.md"
    end
  end
end
