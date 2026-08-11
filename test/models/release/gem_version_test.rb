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

  # THE MUTANT THAT SURVIVED this suite at review: every minor/major case above
  # starts from a `.0` patch, so `"#{major}.#{minor + 1}.#{patch}"` passed all of
  # them. Real tags carry a nonzero patch (0.32.1 shipped), and a minor bump must
  # ZERO the lower segments rather than carry them forward — 0.33.7 + minor is
  # 0.34.0, never 0.34.7.
  def test_a_minor_or_major_bump_zeroes_the_lower_segments
    assert_equal "0.34.0", GV.next_version("0.33.7", [member(kind: "feature")])
    assert_equal "1.0.0", GV.next_version("0.33.7", [member(kind: "chore", risk: ["breaking"])])
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

  # --- allocation: the decision bin/release prepare step 4d makes ---------------
  #
  # Everything above computes a version; this decides whether to WRITE one. The
  # three answers are asserted by action, never by version alone: a `refuse`
  # carrying a nil version and a `skip` carrying a nil version mean opposite
  # things to the caller (abort the sweep vs. carry on), and a test that only
  # checked the version would pass while the two were swapped.

  def allocation(current: "0.4.0", tag: "0.4.0", live: ["0.4.0"], ahead: ["abc1234 work"], members: [member])
    GV.allocation(current: current, tag_version: tag, live_versions: live, ahead_commits: ahead, members: members)
  end

  def test_allocates_the_members_bump_past_the_last_published_version
    decision = allocation(members: [member(kind: "feature")])

    assert_equal GV::ALLOCATE, decision.action
    assert_equal "0.5.0", decision.version
    assert_includes decision.reason, "0.4.0 + minor"
  end

  def test_the_largest_member_bump_wins_the_allocation
    decision = allocation(members: [member(kind: "chore"), member(kind: "feature", slug: "b"),
                                    member(kind: "bug", risk: ["breaking-change"], slug: "c")])

    assert_equal "1.0.0", decision.version, "a breaking member must carry the whole release to a major"
  end

  # The idempotency rule the self-healing re-run depends on. Without it a second
  # `prepare` would allocate 0.6.0 over the 0.5.0 the first one just committed —
  # burning a number every pass and publishing one the release never recorded.
  def test_skips_when_the_version_already_advanced_past_everything_published
    decision = allocation(current: "0.5.0")

    assert_equal GV::SKIP, decision.action
    assert_nil decision.version
    assert_includes decision.reason, "already advanced"
  end

  # A hand-set version is the same shape as a re-run, and must be honoured for
  # the same reason: the operator already made the decision this would override.
  def test_a_hand_bumped_version_is_left_alone
    assert_equal GV::SKIP, allocation(current: "2.0.0").action
  end

  # A publish that landed while its tag push did not. The version IS live, so
  # phase 2 skips it — and allocating a fresh number here would burn one on every
  # re-run for a release that already happened. Whether to allocate is judged
  # against the TAG; only the number itself consults the live list.
  def test_skips_a_version_that_is_published_but_whose_tag_lagged
    decision = allocation(current: "1.0.0", tag: "0.4.0", live: %w[0.4.0 1.0.0])

    assert_equal GV::SKIP, decision.action
    assert_includes decision.reason, "already advanced"
  end

  # With no tag at all the live list becomes the reference, so a repo whose tags
  # never came down still recognises an already-advanced version.
  def test_an_untagged_repo_falls_back_to_the_live_list_as_its_reference
    assert_equal GV::SKIP, allocation(current: "1.0.0", tag: nil, live: ["0.4.0"]).action
    assert_equal GV::ALLOCATE, allocation(current: "0.4.0", tag: nil, live: ["0.4.0"]).action
  end

  def test_skips_when_no_commits_sit_past_the_last_published_tag
    decision = allocation(ahead: [])

    assert_equal GV::SKIP, decision.action
    assert_includes decision.reason, "nothing to publish"
  end

  # The stranded-work guard's own trigger conditions — unbumped, BACKWARD, and
  # unparseable — are exactly the cases allocation must step in and fix. If any
  # of these ever skipped instead, the guard would abort the sweep for every
  # repo and the conductor would be back to hand-editing the version file.
  def test_allocates_over_every_state_the_stranded_work_guard_fires_on
    { "0.4.0" => "unbumped", "0.3.0" => "backward", "" => "missing", "nonsense" => "unparseable" }
      .each do |current, why|
        decision = allocation(current: current, members: [member(kind: "feature")])

        assert_equal GV::ALLOCATE, decision.action, "a #{why} version must be allocated, not skipped"
        assert_equal "0.5.0", decision.version, "a #{why} version must bump from the last PUBLISHED version"
      end
  end

  # --- refusing, the branch that protects an irreversible push -----------------

  # RubyGems will not take the same number twice, so the floor is the highest of
  # BOTH records. A tag that lags a publish (or a repo whose tags never came down)
  # would otherwise re-allocate a live number and hard-fail at `gem push`.
  def test_the_baseline_is_the_highest_of_the_tag_and_the_live_versions
    decision = allocation(current: "0.4.0", tag: "0.4.0", live: %w[0.4.0 0.9.0],
                          members: [member(kind: "feature")])

    assert_equal "0.10.0", decision.version
  end

  def test_never_allocates_a_version_that_is_already_live
    decision = allocation(current: "0.4.0", tag: "0.4.0", live: %w[0.4.0 0.5.0],
                          members: [member(kind: "feature")])

    refute_equal "0.5.0", decision.version, "0.5.0 is published and can never be re-pushed"
    assert_equal "0.6.0", decision.version
  end

  # The versions API answers [{"number" => "…"}]; a caller handing that straight
  # in must still get a working already-live check, not one that silently never
  # matches and allocates a spent number.
  def test_the_live_list_is_read_in_the_versions_api_shape_too
    decision = allocation(current: "0.4.0", tag: "0.4.0",
                          live: [{ "number" => "0.4.0" }, { "number" => "0.9.0" }],
                          members: [member(kind: "feature")])

    assert_equal "0.10.0", decision.version
  end

  # normalize_bump IGNORES a typo on purpose (a bad tag must not wedge a release).
  # Here — the one moment a human can still fix it, and the last moment before an
  # irreversible push — it must refuse instead of quietly publishing the derived
  # bump the operator was trying to override.
  def test_refuses_an_unrecognized_gem_bump_override
    decision = allocation(members: [member(kind: "feature", bump: "mjaor")])

    assert_equal GV::REFUSE, decision.action
    assert_nil decision.version
    assert_includes decision.reason, "mjaor"
  end

  def test_an_understood_override_still_wins
    assert_equal "1.0.0", allocation(members: [member(kind: "chore", bump: "major")]).version
  end

  # MEASURED, 2026-08-11: studio-engine 0.38.0 → 0.39.0, allocated by hand while
  # this was in review. The member was `kind: bug`, but the release REMOVED
  # `--studio-bars-h`, a documented public contract, so the conductor chose minor
  # over the patch the kind scores.
  #
  # This test pins all three answers, because the honest reading matters more than
  # a green tick: the DERIVED bump would have shipped 0.38.1, which was the wrong
  # call. KIND_BUMPS is a floor for routine work, not a judgment about public
  # surface — so removing documented API needs a human to say so, and `gem_bump`
  # is how they say it. The `breaking` risk tag is the other lever, and it reads
  # this change as a major.
  def test_the_studio_engine_0_39_0_call_is_expressible
    engine = { current: "0.38.0", tag: "0.38.0", live: ["0.38.0"] }
    bug    = member(kind: "bug", slug: "drop-studio-bars-h")

    assert_equal "0.38.1", allocation(**engine, members: [bug]).version,
                 "the derived bump alone would have UNDER-called a public-contract removal"
    assert_equal "0.39.0", allocation(**engine, members: [member(kind: "bug", bump: "minor")]).version,
                 "--gem-bump minor expresses the conductor's judgment exactly"
    assert_equal "1.0.0", allocation(**engine, members: [member(kind: "bug", risk: ["breaking"])]).version,
                 "a breaking risk tag reads the same change as a major"
  end

  # And the override fails LOUDLY when mistyped, which matters most precisely
  # here: a silent degrade would hand back the 0.38.1 the human was overriding.
  def test_a_mistyped_override_refuses_rather_than_reverting_to_the_derived_bump
    decision = allocation(current: "0.38.0", tag: "0.38.0", live: ["0.38.0"],
                          members: [member(kind: "bug", bump: "mnior")])

    assert_equal GV::REFUSE, decision.action
    refute_equal "0.38.1", decision.version
  end

  def test_refuses_when_the_last_published_version_cannot_be_parsed
    decision = allocation(tag: "0.4", live: ["0.4"])

    assert_equal GV::REFUSE, decision.action
    assert_includes decision.reason, "cannot parse"
  end

  def test_refuses_when_the_candidate_has_no_gem_members
    decision = allocation(members: [])

    assert_equal GV::REFUSE, decision.action
    assert_includes decision.reason, "no gem members"
  end

  # A gem nobody has published has no floor to derive from, and 0.0.1 would be an
  # invention. Leave the declared version alone and let the publish carry it.
  def test_a_first_publish_is_skipped_not_invented
    decision = allocation(current: "0.1.0", tag: nil, live: [])

    assert_equal GV::SKIP, decision.action
    assert_includes decision.reason, "first publish"
  end

  # --- writing the version back into the version_file --------------------------

  def test_rewrites_both_registered_version_file_shapes
    assert_equal %(module Studio\n  VERSION = "0.39.0"\nend\n),
                 GV.rewrite_version(%(module Studio\n  VERSION = "0.38.0"\nend\n), "0.39.0")
    assert_includes GV.rewrite_version(%(  spec.version       = "0.4.7"\n), "0.5.0"),
                    %(spec.version       = "0.5.0")
  end

  # A gemspec's `required_ruby_version` sits one line away from the version this
  # rewrites. It must not read as a second declaration (which would make the file
  # ambiguous and refuse) nor be rewritten itself.
  def test_a_required_ruby_version_line_is_not_mistaken_for_the_version
    spec = %(  spec.version = "0.4.7"\n  spec.required_ruby_version = ">= 3.0"\n)

    assert_includes GV.rewrite_version(spec, "0.5.0"), %(spec.required_ruby_version = ">= 3.0")
    assert_includes GV.rewrite_version(spec, "0.5.0"), %(spec.version = "0.5.0")
  end

  # Ambiguity is refused, not resolved by picking the first match: this write
  # feeds a push that can never be taken back.
  def test_refuses_to_rewrite_a_file_that_does_not_declare_exactly_one_version
    assert_nil GV.rewrite_version(%(VERSION = "1.0.0"\nOLD_version = "0.9.0"\n), "1.1.0")
    assert_nil GV.rewrite_version("no version declared here", "1.1.0")
    assert_nil GV.rewrite_version(%(VERSION = "1.0.0"\n), "not-a-version")
  end
end
