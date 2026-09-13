# frozen_string_literal: true

require "test_helper"

# [unit] WHICH RUNG PHASE 0 WRITES, pinned in bin/release.rb's own source
# (/tasks/carry-release-commit-onto-accepted, operator decision activity-8874).
#
# The behaviour is driven against real git in test/lib/release_gem_allocation_test.rb.
# What THAT cannot see is the seam itself: `bin/release.rb` is a top-level CLI that
# boots nothing and cannot be loaded into a Rails run (test/lib/session_env_test.rb
# documents why), so the two facts that make the ladder one-way are asserted here,
# in source order: the version commit is pushed to `accepted`, and the repo it was
# written in is handed to the ordinary batch promote, which is the only way anything
# reaches `release`.
class ReleaseAllocationRungTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("bin/release.rb").read.freeze

  def body(name)
    start = SOURCE.index(/^def #{Regexp.escape(name)}[ (]/)
    assert start, "bin/release.rb must define `#{name}`"
    SOURCE[start...(SOURCE.index(/^def /, start + 1) || SOURCE.length)]
  end

  test "the version commit is pushed to accepted, never to release" do
    write = body("commit_gem_version!")

    assert_includes write, 'push", "origin", "HEAD:refs/heads/#{ACCEPTED_BRANCH}"',
                    "phase 0b must write the version, its lock and the rolled changelog onto `accepted`"
    refute_includes write, 'push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}"',
                    "a push to `release` here is the shape that left `accepted` un-rolled"
    assert_includes write, "--force", "the push stays fast-forward-checked" if write.include?("--force")
  end

  test "allocation hands the written repos to the ordinary promote, after the write" do
    phase = body("allocate_gem_versions!")

    commit_at  = phase.index("commit_gem_version!")
    promote_at = phase.index("promote_accepted_to_release!")
    assert commit_at, "allocation must still write the version commit"
    assert promote_at, "and must hand the written repo to the batch promote — nothing else reaches `release`"
    assert_operator commit_at, :<, promote_at, "the promote carries what was just written, so it runs after it"
    assert_includes phase, "abort_allocation!(failures)",
                    "and a refusal still aborts before anything is promoted"
  end

  # The direction itself. A push of `release` onto `accepted` anywhere in phase 0
  # would be the rejected alternative (carrying a commit back DOWN the ladder).
  test "phase 0 never carries release back onto accepted" do
    phase = body("allocate_gem_versions!") + body("commit_gem_version!") + body("gem_allocation_plan")

    refute_match(/origin\/#\{RELEASE_BRANCH\}:refs\/heads\/#\{ACCEPTED_BRANCH\}/, phase,
                 "the ladder is one-way: `release` is never pushed onto `accepted`")
  end
end
