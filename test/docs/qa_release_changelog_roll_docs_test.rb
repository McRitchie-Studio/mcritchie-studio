# frozen_string_literal: true

require "test_helper"

# GUARD (document-changelog-roll-for-conductors, 2026-09-10): qa-release.md step 4d
# tells the conductor when `bin/release prepare` rolls a gem's CHANGELOG.md and
# when it does not. The roll runs ONLY for an ALLOCATE: `roll_changelog!` is
# reached from `commit_gem_version!`, which runs only for the entries
# `gem_allocation_plan` returns past its `allocate?` gate. So every SKIP is a
# release whose `## Unreleased` entries stay unrolled — and a version set by hand
# lands in one. A SKIP reason the SOP does not name is a silent no-roll path the
# conductor cannot recognise in the prepare log.
#
# WHY NOT A KEYWORD LIST (see credential_rotation_sop_docs_test.rb): words survive
# any rewording that guts a procedure. This guard reads the reasons from the CODE
# and asks the SOP to quote each one, so it reddens when the code grows a SKIP
# path the SOP never mentions — not when the prose is reworded.
#
# Every scan asserts a FLOOR before it grades, so a selector that stops matching
# fails loudly instead of passing over an empty set.
class QaReleaseChangelogRollDocsTest < ActiveSupport::TestCase
  SOP         = Rails.root.join("docs/agents/agents/avi/sops/qa-release.md")
  GEM_VERSION = Rails.root.join("app/models/release/gem_version.rb")
  ROWS        = ["CHANGELOG BACKLOG", "GEM VERSION ALLOCATION REFUSED", "STRANDED GEM WORK"].freeze

  # Step 4d, from its own marker to the next top-level step, whitespace collapsed
  # because the SOP wraps a quoted reason across lines.
  def step_4d
    text   = SOP.read
    start  = text.index(/^4d\. \*\*Allocate gem versions/)
    finish = start && text.index(/^5\. /, start)
    assert start, "qa-release.md lost its step 4d marker"
    assert finish, "qa-release.md lost the step 5 marker that closes 4d"

    section = text[start...finish].gsub(/\s+/, " ")
    assert_operator section.length, :>, 4_000, "the step 4d slice is implausibly short — a marker moved"
    section
  end

  # Every literal run of every `skip_decision("…")` reason in the source, split
  # around its interpolations (`#{current}` is data, not prose to quote).
  def skip_reason_fragments
    literals = GEM_VERSION.read.scan(/skip_decision\("((?:[^"\\]|\\.)*)"\)/).flatten
    assert_operator literals.size, :>=, 3,
      "found #{literals.size} skip_decision literals in gem_version.rb — the scan broke, or SKIP paths were removed"

    literals.flat_map { |lit| lit.split(/#\{[^}]*\}/).map(&:strip).reject { |f| f.length < 8 } }
  end

  test "[static] step 4d quotes every SKIP reason Release::GemVersion.allocation can return" do
    fragments = skip_reason_fragments
    assert_operator fragments.size, :>=, 3
    section = step_4d

    fragments.each do |fragment|
      assert_includes section, fragment,
        "qa-release.md step 4d does not quote the SKIP reason #{fragment.inspect}. A SKIP rolls no " \
        "changelog, so the conductor must be able to find each reason in the prepare log"
    end
  end

  test "[static] step 4d defines the three outcomes by the code's own action names" do
    actions = [Release::GemVersion::ALLOCATE, Release::GemVersion::SKIP, Release::GemVersion::REFUSE]
    assert_equal 3, actions.uniq.size
    section = step_4d

    actions.each do |action|
      assert_includes section, "**#{action.upcase}**",
        "step 4d must define #{action.upcase} — the vocabulary is Release::GemVersion's decision names"
    end
  end

  test "[static] every abort-table row step 4d points at exists" do
    text    = SOP.read
    section = step_4d

    ROWS.each do |row|
      assert_includes section, "#{row} row", "step 4d no longer points at the #{row} row"
      assert_match(/^\| \*\*#{Regexp.escape(row)}/, text, "the #{row} row step 4d points at is gone")
    end
  end
end
