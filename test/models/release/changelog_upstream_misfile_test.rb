# frozen_string_literal: true

# [unit] The rules behind the UPSTREAM changelog misfile detector
# (/tasks/detect-upstream-changelog-misfiles), driven with plain strings.
#
# The detector answers ONE question of ONE tree — does any entry sitting under a
# SHIPPED heading post-date that version's v* tag? — and the naive form of that
# question is unusable: asked of every line under every shipped heading it reported
# 158 lines across 12 versions in studio-engine and 11 across 3 in
# solana-studio (2026-09-14, at origin/accepted), the same refusal the promote guard's first cut hit and rejected.
# Two legitimate populations produce those, and each test below owns one:
#
#   REWORDING — a shipped section edited after release. Excluded because the commit
#   that wrote the line already had it under the VERSION heading.
#   BACKFILL — a version heading inserted ABOVE entries written under `## Unreleased`
#   long before (the documented backlog remedy; 48 of studio-engine's 105 shipped sections).
#   Excluded because the tag's file never carried the heading, so it is no baseline.
#
# SHAPE ONLY, like its sibling: no assertion names a feature or a word of anybody's
# prose, so ordinary changelog writing can never turn this red.
#
#   ruby -Itest test/models/release/changelog_upstream_misfile_test.rb

require "minitest/autorun"
require_relative "../../../app/models/release/changelog"

class ReleaseChangelogUpstreamMisfileRulesTest < Minitest::Test
  SHIPPED = "0.40.0"

  # What `accepted` looks like after the roll AND a stale branch's merge: `- entry
  # two` was written into the bucket upstream and landed under a shipped heading.
  MISFILED = "# Changelog\n\n## Unreleased\n\n## 0.40.0 — 2026-09-14\n\n### Fixed\n\n" \
             "- entry one\n- entry two\n\n## 0.39.0 — 2026-08-11\n\n- older entry\n"

  # The same file at v0.40.0: the roll had happened, the stale bullet had not arrived.
  AT_TAG = "# Changelog\n\n## Unreleased\n\n## 0.40.0 — 2026-09-14\n\n### Fixed\n\n" \
           "- entry one\n\n## 0.39.0 — 2026-08-11\n\n- older entry\n"

  # The stale branch's own tree: it never saw the roll, so its bullet sits in the
  # bucket, which is where its author put it.
  UPSTREAM = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- entry one\n- entry two\n\n" \
             "## 0.39.0 — 2026-08-11\n\n- older entry\n"

  def tags(map) = ->(version) { map[version] }
  def wrote(text) = ->(_number) { text }

  def find(text, published: [SHIPPED], at_tag: tags(SHIPPED => AT_TAG), origin: wrote(UPSTREAM))
    Release::Changelog.upstream_misfiled_entries(text, published: published, at_tag: at_tag, origin: origin)
  end

  def test_an_entry_filed_under_a_shipped_version_is_detected
    found = find(MISFILED)

    assert_equal 1, found.size
    assert_equal SHIPPED, found.first[:version]
    assert_equal "- entry two", found.first[:line].strip
    assert_equal 10, found.first[:number]
  end

  def test_the_notice_names_the_line_the_version_and_the_remedy
    notice = Release::Changelog.upstream_misfile_notice(find(MISFILED))

    assert_includes notice, "- entry two"
    assert_includes notice, SHIPPED
    assert_includes notice, "line 10"
    assert_includes notice, Release::Changelog::UPSTREAM_MISFILE_REMEDY
  end

  def test_an_honest_file_reports_nothing
    assert_empty find(AT_TAG)
    assert_nil Release::Changelog.upstream_misfile_notice(find(AT_TAG))
    assert_nil Release::Changelog.upstream_misfile_notice([])
  end

  # A line still sitting in the bucket is pending, not mis-filed, wherever it came from.
  def test_a_line_still_under_unreleased_is_not_judged
    pending = MISFILED.sub("## Unreleased\n", "## Unreleased\n\n- entry three\n")

    refute(find(pending).any? { |m| m[:line].include?("entry three") })
  end

  # S1 — an untagged heading is the IN-FLIGHT version: its entries ship in it.
  def test_an_unpublished_version_is_not_judged
    assert_empty find(MISFILED, published: [])
    assert_empty find(MISFILED, published: ["0.39.0"])
  end

  # S2 — BACKFILL. The tag's file has the entries under `## Unreleased` and no heading
  # for the version at all, so it cannot be a baseline for that section.
  def test_a_section_whose_heading_postdates_its_tag_is_not_judged
    backfilled = tags(SHIPPED => UPSTREAM)

    assert_empty find(MISFILED, at_tag: backfilled)
    assert_empty Release::Changelog.upstream_judged_entries(MISFILED, published: [SHIPPED], at_tag: backfilled)
  end

  # …and an unreadable tag is not a clean verdict either: nothing is judged.
  def test_an_unreadable_tag_judges_nothing
    assert_empty find(MISFILED, at_tag: tags({}))
  end

  # L3 — REWORDING. The line post-dates the tag exactly like a misfile does, but its
  # author wrote it under the VERSION heading, not the bucket.
  def test_a_line_its_author_filed_under_the_version_is_not_a_misfile
    assert_empty find(MISFILED, origin: wrote(MISFILED))
  end

  # An unreadable origin cannot prove a misfile, so it does not claim one.
  def test_an_unreadable_origin_claims_nothing
    assert_empty find(MISFILED, origin: ->(_n) { nil })
  end

  # The population the silence is a statement about — exposed so it can never be a
  # vacuum. Here: the two `- entry` lines under 0.40.0, and nothing from the bucket,
  # the `###` heading, the blank lines or the untagged 0.39.0 section.
  def test_the_judged_population_is_the_shipped_sections_entry_lines
    judged = Release::Changelog.upstream_judged_entries(MISFILED, published: [SHIPPED],
                                                        at_tag: tags(SHIPPED => AT_TAG))

    assert_equal ["- entry one", "- entry two"], judged.map { |e| e[:line].strip }.sort
    assert_equal [SHIPPED], judged.map { |e| e[:version] }.uniq
  end

  # A `## ` line quoted inside a fenced block is content, and the detector inherits
  # that from the module's one fence scan rather than re-deciding it.
  def test_a_fenced_heading_does_not_move_a_section_boundary
    fenced = MISFILED.sub("- entry one\n", "- entry one\n\n```markdown\n## 9.9.9 — 2026-01-01\n```\n\n")
    baseline = AT_TAG.sub("- entry one\n", "- entry one\n\n```markdown\n## 9.9.9 — 2026-01-01\n```\n\n")

    found = find(fenced, at_tag: tags(SHIPPED => baseline))

    assert_equal [SHIPPED], found.map { |m| m[:version] }
    assert_equal ["- entry two"], found.map { |m| m[:line].strip }
  end
end
