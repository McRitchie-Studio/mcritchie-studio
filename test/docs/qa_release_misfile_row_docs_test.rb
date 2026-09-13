# frozen_string_literal: true

require "test_helper"

# [static] qa-release.md's abort table must carry a row for the promote-time
# CHANGELOG misfile guard (refuse_misfiled_changelog!, /tasks/rolled-changelog-merge-misfiles).
# A conductor who hits a refusal searches the SOP's abort table first; before
# /tasks/correct-conductor-release-prose the guard was documented in deployment.md
# only, so that search found nothing.
#
# Every quoted fragment is READ OUT OF THE SOURCE, never typed here, so the row
# cannot keep quoting a message the code has stopped printing.
class QaReleaseMisfileRowDocsTest < ActiveSupport::TestCase
  SOP       = Rails.root.join("docs/agents/agents/avi/sops/qa-release.md")
  RELEASE   = Rails.root.join("bin/release.rb")
  CHANGELOG = Rails.root.join("app/models/release/changelog.rb")

  def row
    @row ||= SOP.read.lines.find { |line| line.start_with?("| **CHANGELOG MISFILE GUARD REFUSED THE PROMOTE**") }
  end

  # The static fragment containing `anchor`, joined across a continued string.
  def literal(path, anchor)
    lines = path.read.lines
    index = lines.index { |line| line.include?(anchor) }
    assert index, "#{path.basename} no longer contains #{anchor.inspect} — the scan broke, or the message moved"

    source = [lines[index]]
    source << lines[index + source.length] while source.last.rstrip.end_with?("\\")
    fragments = source.join.scan(/"((?:\\.|[^"])*)"/m).flatten.join.split(/#\{[^}]+\}/)
    fragment = fragments.find { |part| part.include?(anchor) }
    assert fragment, "#{path.basename} no longer quotes #{anchor.inspect} in that source string"
    fragment.squish
  end

  test "[static] the abort table has a row for the promote-time misfile guard" do
    assert row, "qa-release.md's abort table lost the CHANGELOG MISFILE GUARD REFUSED THE PROMOTE row"
  end

  test "[static] the row quotes the abort headline and both per-gem refusals the code prints" do
    headline = literal(RELEASE, "the CHANGELOG misfile guard REFUSED the promote").split(":").first
    misfile  = literal(CHANGELOG, "written under '## Unreleased' beneath a version").delete_suffix("(").strip
    filename = RELEASE.read[/^CHANGELOG_FILE = "([^"]+)"/, 1]
    assert filename, "bin/release.rb no longer declares CHANGELOG_FILE as a literal"
    conflict = "#{literal(RELEASE, "the promote would CONFLICT in")} #{filename}"

    [headline, misfile, conflict].each do |fragment|
      assert_operator fragment.length, :>, 15, "a source fragment came back implausibly short: #{fragment.inspect}"
      assert_includes row, fragment, "the row does not quote #{fragment.inspect}, which the code prints"
    end
  end

  test "[static] the row gives the remedy the refusal prints: a direct push, not a PR" do
    # The constant is a string continued across lines: join its quoted segments.
    source = CHANGELOG.read
    start = source.index("MISFILE_REMEDY = ")
    assert start, "Release::Changelog::MISFILE_REMEDY is gone — re-read the refusal before re-wording the row"
    remedy = source[start..].lines.take_while.with_index { |l, i| i.zero? || source[start..].lines[i - 1].rstrip.end_with?("\\") }
                   .map { |l| l[/"([^"]*)"/, 1] }.join
    assert_includes remedy, "straight onto `accepted`", "the code's remedy changed; re-read it before re-wording the row"
    assert_includes row, "straight onto `accepted`"
    assert_includes row, "**not a PR**"
  end
end
