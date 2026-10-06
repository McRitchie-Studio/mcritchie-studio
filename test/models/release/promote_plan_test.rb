# frozen_string_literal: true

require "test_helper"

# Release::PromotePlan is the pure decision behind `bin/release prepare`'s
# `accepted → release` promote: a fast-forward ref push when `release` is contained
# in `accepted`, the batch PR only when `release` has diverged. It also decides the
# carry of `release` back onto `accepted` and the branch a consumer lock bump lands
# on. Rails-free (bin/release loads it standalone), so these are plain unit tests.
class Release::PromotePlanTest < ActiveSupport::TestCase
  P = Release::PromotePlan
  REL = "1111111111111111111111111111111111111111".freeze
  ACC = "2222222222222222222222222222222222222222".freeze
  OTHER = "3333333333333333333333333333333333333333".freeze

  test "[unit] the promote fast-forwards when release IS the merge base (contained in accepted)" do
    assert_equal :fast_forward, P.promote(ahead: 3, release_sha: REL, merge_base: REL)
  end

  test "[unit] the promote takes the batch PR when release carries a commit accepted lacks" do
    assert_equal :batch_pr, P.promote(ahead: 3, release_sha: REL, merge_base: OTHER),
                 "a merge base older than release means release diverged: no fast-forward exists"
  end

  test "[unit] the promote does nothing when accepted is level with release" do
    assert_equal :level, P.promote(ahead: 0, release_sha: REL, merge_base: REL)
    assert_equal :level, P.promote(ahead: 0, release_sha: REL, merge_base: OTHER),
                 "ahead zero wins over containment: there is nothing to land"
  end

  test "[unit] an unreadable containment answer degrades to the batch PR, never the push" do
    assert_equal :batch_pr, P.promote(ahead: 2, release_sha: "", merge_base: "")
    assert_equal :batch_pr, P.promote(ahead: 2, release_sha: REL, merge_base: "")
    assert_equal :batch_pr, P.promote(ahead: 2, release_sha: "", merge_base: REL)
    assert_equal :batch_pr, P.promote(ahead: 2, release_sha: "  ", merge_base: "  "),
                 "two blanks are equal strings, and must still prove nothing"
  end

  test "[unit] a merge base read with its trailing newline still proves containment" do
    assert_equal :fast_forward, P.promote(ahead: 1, release_sha: REL, merge_base: "#{REL}\n")
  end

  test "[unit] carry_back fast-forwards accepted when accepted is contained in release" do
    assert_equal :fast_forward, P.carry_back(release_sha: REL, accepted_sha: ACC, merge_base: ACC)
  end

  test "[unit] carry_back leaves accepted alone when it gained a commit meanwhile" do
    assert_equal :diverged, P.carry_back(release_sha: REL, accepted_sha: ACC, merge_base: OTHER)
  end

  test "[unit] carry_back is level on one commit and unreadable on a blank SHA" do
    assert_equal :level, P.carry_back(release_sha: REL, accepted_sha: REL, merge_base: REL)
    assert_equal :unreadable, P.carry_back(release_sha: "", accepted_sha: ACC, merge_base: "")
    assert_equal :unreadable, P.carry_back(release_sha: REL, accepted_sha: "", merge_base: "")
  end

  test "[unit] the lock bump lands on accepted only when the two branches share a commit" do
    assert_equal :accepted, P.bump_rung(release_sha: REL, accepted_sha: REL)
    assert_equal :release, P.bump_rung(release_sha: REL, accepted_sha: ACC),
                 "a bump built on release and pushed to a different accepted would not fast-forward"
    assert_equal :release, P.bump_rung(release_sha: "", accepted_sha: ""),
                 "unreadable is the diverged path, never a guess that they match"
  end
end
