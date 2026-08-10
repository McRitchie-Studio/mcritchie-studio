# frozen_string_literal: true

# [unit] The release-owned gem version computation.
#
# This output feeds an IRREVERSIBLE `gem push`, so the tests below are deliberately
# adversarial about the two directions that hurt: inventing a version when there is
# nothing to publish, and silently under- or over-bumping.
#
#   ruby -Itest test/models/release/gem_version_test.rb

require "minitest/autorun"
require_relative "../../../app/models/release/gem_version"

class ReleaseGemVersionTest < Minitest::Test
  GV = Release::GemVersion

  def member(kind: "chore", risk: [], bump: nil, slug: "a-task")
    { "kind" => kind, "risk_tags" => risk, "gem_bump" => bump, "slug" => slug }
  end

  # --- what one member earns ---------------------------------------------------

  def test_kind_drives_the_default_bump
    assert_equal "minor", GV.member_bump(member(kind: "feature"))
    assert_equal "patch", GV.member_bump(member(kind: "bug"))
    assert_equal "patch", GV.member_bump(member(kind: "chore"))
  end

  # An unknown kind takes the SMALLEST bump on purpose: a too-small version is
  # fixable by bumping again, an unearned major is permanent.
  def test_unknown_or_blank_kind_degrades_to_patch
    assert_equal "patch", GV.member_bump(member(kind: "experiment"))
    assert_equal "patch", GV.member_bump(member(kind: ""))
    assert_equal "patch", GV.member_bump({})
  end

  # Risk tags are hand-typed free text, so the match is loose by design — missing a
  # genuine breaking change is the expensive direction.
  def test_a_breaking_risk_tag_forces_major_whatever_the_kind
    assert_equal "major", GV.member_bump(member(kind: "chore", risk: ["breaking"]))
    assert_equal "major", GV.member_bump(member(kind: "bug", risk: %w[ui breaking-change]))
    assert_equal "major", GV.member_bump(member(kind: "chore", risk: ["BREAKING API"]))
  end

  def test_an_explicit_override_beats_both_kind_and_tags
    assert_equal "major", GV.member_bump(member(kind: "chore", bump: "major"))
    assert_equal "patch", GV.member_bump(member(kind: "feature", bump: "patch")),
                 "an operator may deliberately under-bump a feature"
    assert_equal "minor", GV.member_bump(member(kind: "chore", risk: ["breaking"], bump: "minor")),
                 "an explicit call overrides even the breaking tag — someone said so on purpose"
  end

  def test_a_typo_override_falls_back_to_the_derived_bump
    assert_equal "minor", GV.member_bump(member(kind: "feature", bump: "MAJOR-ish")),
                 "a typo degrades to the default rather than wedging a release"
    assert GV.invalid_bump?("MAJOR-ish"), "…but the CLI can still reject it where a human can fix it"
    refute GV.invalid_bump?("")
    refute GV.invalid_bump?("major")
  end

  # --- what the RELEASE earns --------------------------------------------------

  def test_the_largest_member_bump_wins
    assert_equal "minor", GV.release_bump([member(kind: "chore"), member(kind: "feature"), member(kind: "bug")])
    assert_equal "major", GV.release_bump([member(kind: "chore"), member(kind: "chore", risk: ["breaking"])])
    assert_equal "patch", GV.release_bump([member(kind: "bug"), member(kind: "chore")])
  end

  # THE CASE THAT MUST NEVER INVENT A NUMBER: no members means nothing to publish.
  def test_no_members_yields_no_version
    assert_nil GV.release_bump([])
    assert_nil GV.next_version("0.33.0", [])
    assert_nil GV.next_version("0.33.0", nil)
  end

  # --- the published number ----------------------------------------------------

  def test_next_version_advances_correctly
    assert_equal "0.34.0", GV.next_version("0.33.0", [member(kind: "feature")])
    assert_equal "0.33.1", GV.next_version("0.33.0", [member(kind: "chore")])
    assert_equal "1.0.0",  GV.next_version("0.33.0", [member(kind: "chore", risk: ["breaking"])])
  end

  def test_a_leading_v_is_tolerated_because_tags_carry_one
    assert_equal "0.34.0", GV.next_version("v0.33.0", [member(kind: "feature")])
  end

  # The real scenario from 2026-08-10: three members, mixed kinds, one published tag.
  def test_the_measured_collision_scenario_resolves_to_one_version
    members = [member(kind: "feature", slug: "standard-transactional-email-primitive"),
               member(kind: "chore", slug: "fold-email-preview-into-registry"),
               member(kind: "chore", slug: "local-review-provisions-admin")]

    assert_equal "0.34.0", GV.next_version("0.33.0", members),
                 "one candidate, one version — no PR needed to guess"
    assert_includes GV.explain("0.33.0", members), "standard-transactional-email-primitive",
                    "and the log names WHICH member drove the bump"
  end

  # --- refusing to guess -------------------------------------------------------

  def test_an_unparseable_last_version_yields_nil_never_a_guess
    [nil, "", "not-a-version", "1.2", "1.2.3.4"].each do |bad|
      assert_nil GV.next_version(bad, [member(kind: "feature")]), "must refuse to publish from #{bad.inspect}"
    end
  end

  # Pre-release metadata is not something this pipeline publishes; truncating it
  # into a release version would be a silent, irreversible mistake.
  def test_prerelease_and_build_metadata_are_refused_not_truncated
    assert_nil GV.advance("1.2.3-rc1", "patch")
    assert_nil GV.advance("1.2.3+build7", "patch")
  end

  def test_explain_says_so_when_there_is_nothing_to_publish
    assert_includes GV.explain("0.33.0", []), "nothing to publish"
  end
end
