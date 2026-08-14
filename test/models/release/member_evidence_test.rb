# frozen_string_literal: true

require "test_helper"

# Release::MemberEvidence is the PURE per-repo evidence rule behind the `assembled`
# and `shipped` stamps: may this member be stamped, given what the release run
# actually landed repo by repo? Rails-free, so these are plain in-process unit
# tests. The EFFECT of the rule (a member that must not reach assembled/shipped)
# lives in test/models/release/multi_repo_member_test.rb.
class Release::MemberEvidenceTest < ActiveSupport::TestCase
  test "[unit] a member whose every repo is proven is not held" do
    refute Release::MemberEvidence.hold?(
      repos: %w[mcritchie-studio turf-monster],
      proven: %w[mcritchie-studio turf-monster mcritchie-industries]
    )
  end

  test "[unit] the 2026-08-13 shape: a two-repo member with one repo proven is HELD" do
    repos  = %w[mcritchie-studio turf-monster]
    proven = %w[mcritchie-studio mcritchie-industries]

    assert_equal ["turf-monster"], Release::MemberEvidence.unproven(repos: repos, proven: proven)
    assert Release::MemberEvidence.hold?(repos: repos, proven: proven)
  end

  test "[unit] a multi-repo member is held even when the release recorded NO evidence" do
    # The stronger of the two entitlements. A release that recorded nothing per repo
    # asserts nothing — but a member naming several repos is the only shape in which
    # a repo can vanish from the plan unnoticed, so it must show evidence regardless.
    assert Release::MemberEvidence.hold?(repos: %w[mcritchie-studio turf-monster], proven: [])
  end

  test "[unit] a SINGLE-repo member is not held by a release that recorded nothing" do
    # The stated gap: the model-driven path (Conductor.prepare! with no real deploy)
    # records no per-repo evidence, and holding every member of it would be a dead
    # pipeline, not a safety property.
    refute Release::MemberEvidence.hold?(repos: ["mcritchie-studio"], proven: [])
  end

  test "[unit] a single-repo member IS held once the release recorded evidence elsewhere" do
    # Once a run has shown what it landed, every member is held to that record.
    assert Release::MemberEvidence.hold?(repos: ["turf-monster"], proven: ["mcritchie-studio"])
  end

  test "[unit] an exempt (gem) repo needs no evidence" do
    # Gems publish rather than deploy: no QA sha, no ff'd `main`. Demanding one
    # would hold every gem member forever.
    refute Release::MemberEvidence.hold?(
      repos: %w[studio-engine mcritchie-studio],
      proven: ["mcritchie-studio"],
      exempt: ["studio-engine"]
    )
  end

  test "[unit] an exempt repo does not rescue a genuinely unproven sibling" do
    assert Release::MemberEvidence.hold?(
      repos: %w[studio-engine mcritchie-studio turf-monster],
      proven: ["mcritchie-studio"],
      exempt: ["studio-engine"]
    )
  end

  test "[unit] blanks and duplicates never fabricate a repo to prove" do
    refute Release::MemberEvidence.hold?(repos: ["mcritchie-studio", "", "mcritchie-studio", nil],
                                         proven: ["mcritchie-studio"])
  end

  test "[unit] hold_reason names the unproven repos and the stamp it refused" do
    reason = Release::MemberEvidence.hold_reason(
      slug: "land-rails-security-patch",
      repos: %w[mcritchie-studio turf-monster],
      proven: ["mcritchie-studio"],
      stamp: "shipped"
    )

    assert_includes reason, "land-rails-security-patch"
    assert_includes reason, "turf-monster"
    assert_includes reason, "shipped"
    refute_includes reason.sub("mcritchie-studio,", ""), "landed nothing for mcritchie-studio",
                    "a proven repo must not be named as missing"
  end
end
