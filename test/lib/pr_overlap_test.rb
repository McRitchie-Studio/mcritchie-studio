# frozen_string_literal: true

# [unit] The ship-time same-file overlap advisory. Pure by construction — the caller
# supplies the file lists — so every rule is asserted without a network or a gh.
#
#   ruby -Itest test/lib/pr_overlap_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/pr_overlap"

class PrOverlapTest < Minitest::Test
  def pr(number, files, title: "Some PR")
    { "number" => number, "title" => title, "url" => "https://github.com/o/r/pull/#{number}",
      "files" => files }
  end

  def test_reports_only_prs_that_share_a_file
    items = PrOverlap.report(%w[a.rb b.rb], [pr(1, %w[b.rb]), pr(2, %w[z.rb])])
    assert_equal [1], items.map { |i| i["number"] }
    assert_equal %w[b.rb], items.first["files"]
  end

  def test_no_changed_files_reports_nothing
    assert_empty PrOverlap.report([], [pr(1, %w[a.rb])])
    assert_empty PrOverlap.report(nil, [pr(1, %w[a.rb])])
  end

  # The loudest collision is read first — a PR sharing three files matters more than
  # one sharing a stray fixture.
  def test_most_overlapping_pr_sorts_first
    items = PrOverlap.report(%w[a.rb b.rb c.rb],
                             [pr(1, %w[c.rb]), pr(2, %w[a.rb b.rb c.rb])])
    assert_equal [2, 1], items.map { |i| i["number"] }
  end

  def test_lines_are_empty_when_nothing_overlaps
    assert_empty PrOverlap.lines([])
  end

  # THE CASE THIS EXISTS FOR — reproduced from the live 2026-08-10 collision:
  # studio-engine #85 and #87 both set lib/studio/version.rb to 0.33.0. It merges
  # clean (identical line), so only an advisory can surface it.
  def test_version_file_overlap_names_the_stranded_work_risk
    items = PrOverlap.report(%w[lib/studio/version.rb CHANGELOG.md],
                             [pr(85, %w[lib/studio/version.rb CHANGELOG.md])])
    text = PrOverlap.lines(items).join("\n")

    assert_includes text, "PR #85"
    assert_includes text, "lib/studio/version.rb"
    assert_includes text, "stranded-work guard", "the warning must name the ACTUAL consequence"
    assert_includes text, "single dated entry", "and the CHANGELOG remedy"
    assert_includes text, "SEPARATELY", "and the condition that makes it dangerous"
  end

  # A version.rb anywhere (any gem layout) still earns the hint — matched on basename,
  # not one hardcoded path.
  def test_ledger_hint_matches_on_basename
    refute_nil PrOverlap.ledger_hint(%w[some/deep/path/version.rb])
    refute_nil PrOverlap.ledger_hint(%w[config/e2e_lane.yml])
    assert_nil PrOverlap.ledger_hint(%w[app/models/user.rb])
  end

  # An ordinary code overlap is reported WITHOUT a scare line — the advisory has to
  # stay quiet enough to be read when it is loud.
  def test_ordinary_overlap_carries_no_ledger_warning
    text = PrOverlap.lines(PrOverlap.report(%w[app/models/user.rb], [pr(3, %w[app/models/user.rb])])).join("\n")
    assert_includes text, "PR #3"
    refute_includes text, "⚠"
  end
end
