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

  # A body with its full-line COMMENT text removed. Load-bearing, not tidiness:
  # the seam's own comment reads "Fast-forward-checked (no --force)", so a force
  # check run against the raw body is satisfied by the DOCUMENTATION and could
  # only ever be cleared by deleting the sentence that explains the rule.
  def code_only(body)
    body.gsub(/^[ \t]*#.*\n/, "")
  end

  test "the version commit is pushed to accepted, never to release" do
    write = body("commit_gem_version!")

    assert_includes write, 'push", "origin", "HEAD:refs/heads/#{ACCEPTED_BRANCH}"',
                    "phase 0b must write the version, its lock and the rolled changelog onto `accepted`"
    refute_includes write, 'push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}"',
                    "a push to `release` here is the shape that left `accepted` un-rolled"

    # THE PUSH STAYS FAST-FORWARD-CHECKED, and that means NO force in the argv —
    # the refutation, not the assertion this replaces, which demanded the very
    # flag its message forbade and was made unfailable by a trailing modifier-if.
    # `accepted` is the rung merged review work lands on, so a force-push here
    # would displace a merge that landed while the sweep ran, and report success.
    # A lease is refused too: it fails closed on a moved ref, but it is still not
    # the plain fast-forward this rung is documented to make.
    code = code_only(write)
    refute_match(/"--?f(?:orce)?(?:-with-lease)?"/, code,
                 "the push stays fast-forward-checked: no force flag belongs in this argv")
    refute_match(%r{"\+[^"]*refs/heads}, code,
                 "a leading `+` is a force refspec — the push stays fast-forward-checked")
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
    phase = code_only(body("allocate_gem_versions!") + body("commit_gem_version!") + body("gem_allocation_plan"))

    # Pinning ONE literal refspec is how this guard goes blind. The identical
    # defect spelled with gem_allocation_plan's own `release_tip` variable — or
    # with a bare `origin/release` source, or a raw SHA — sails past an exact
    # match. So read every refspec phase 0 actually pushes and hold each one to
    # the rule instead: onto `accepted`, only the workspace's own HEAD.
    specs = phase.scan(/"push",\s*"origin",\s*"([^"]*)"/).flatten
    refute_empty specs, "phase 0 must still push something — an empty scan would assert nothing"

    onto_accepted = specs.select { |spec| /ACCEPTED_BRANCH|accepted/.match?(spec.split(":").last.to_s) }
    refute_empty onto_accepted, "phase 0b must still write the version commit onto `accepted`"

    onto_accepted.each do |spec|
      assert_equal "HEAD", spec.split(":").first,
                   "the ladder is one-way: only the workspace's own HEAD may be pushed onto `accepted`, " \
                   "and `#{spec}` carries something else back DOWN it"
    end
  end
end
