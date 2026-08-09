require "test_helper"

# The merge-forward guard's two STRUCTURAL invariants, asserted against
# bin/release.rb's own source.
#
# Both are properties no behavioural test can hold onto, because the way they
# break is by someone moving a line — and every functional test still passes when
# they do. That is exactly how the rel-20260809-3b8f3d incident happened, so the
# guard is pinned where it can actually be broken: in the source order and in the
# choice of working tree.
#
# THE INCIDENT. The guard used to live inside the QA-deploy loop and merge in the
# SHARED PRIMARY CHECKOUT. The hub primary had an uncommitted file, `git checkout
# release` refused, its result was discarded, the following `git merge origin/main`
# therefore ran against `main` and reported "Already up to date", and the push sent
# a stale local branch that origin rejected. The step was non-fatal, so the sweep
# assembled a candidate whose release branch was missing a hotfix already live in
# production. Placement made it worse: sitting AFTER the pre-QA gate, a merge that
# DID land moved origin/release past the SHA the gate had just certified.
class ReleaseMergeForwardTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("bin/release.rb").read.freeze

  # The body of `def prepare ... end`, which is where the ordering lives.
  def prepare_body
    @prepare_body ||= begin
      start = SOURCE.index(/^def prepare\b/)
      assert start, "bin/release.rb must define `prepare`"
      stop = SOURCE.index(/^def /, start + 1) || SOURCE.length
      SOURCE[start...stop]
    end
  end

  def guard_body
    @guard_body ||= begin
      start = SOURCE.index(/^def merge_forward_release_branches\b/)
      assert start, "bin/release.rb must define `merge_forward_release_branches`"
      stop = SOURCE.index(/^def /, start + 1) || SOURCE.length
      SOURCE[start...stop]
    end
  end

  # INVARIANT 1 — ORDER. The gate certifies a SHA; the merge-forward can move that
  # SHA. So the merge must happen first, or the gate's verdict describes a tree
  # that is not the one QA deploys and ship freezes.
  test "prepare runs the merge-forward BEFORE the pre-QA gate" do
    merge_at = prepare_body.index("merge_forward_release_branches(")
    gate_at  = prepare_body.index("pre_qa_gate(")

    assert merge_at, "prepare must call merge_forward_release_branches"
    assert gate_at,  "prepare must call pre_qa_gate"
    assert_operator merge_at, :<, gate_at,
                    "the merge-forward must precede the pre-QA gate — running it after (its old home " \
                    "in the QA-deploy loop) moves origin/release past the SHA the gate just certified"
  end

  # It must also precede the QA deploy, for the same reason one step further on.
  test "prepare runs the merge-forward BEFORE the QA deploy loop" do
    merge_at  = prepare_body.index("merge_forward_release_branches(")
    deploy_at = prepare_body.index(/record_release_event\([^)]*"deploy_qa", "started"\)/)

    assert deploy_at, "prepare must open the deploy_qa stage"
    assert_operator merge_at, :<, deploy_at
  end

  # INVARIANT 2 — WORKING TREE. The merge runs in a detached workspace. A checkout
  # in the shared primary is what a dirty ledger file was able to refuse, and the
  # primary belongs to whatever else the operator is doing.
  test "the merge-forward never checks out a branch in the primary checkout" do
    assert_not_includes guard_body, %("checkout"),
                        "the merge must happen in a detached ship workspace, never by flipping the " \
                        "primary's HEAD — a dirty primary made that checkout fail and the failure was " \
                        "then discarded"
    assert_includes guard_body, "with_ship_workspace",
                    "the merge runs in the same detached workspace mechanics the rest of the ship path uses"
  end

  # INVARIANT 3 — every step is CHECKED. The original discarded the checkout's
  # result and only tested the merge, which is how a no-op on the wrong branch read
  # as success. Each fallible step must feed an abort.
  test "the merge-forward aborts rather than continuing non-fatally" do
    %w[fetch merge push].each do |verb|
      assert_includes guard_body, verb, "the guard still performs the #{verb}"
    end

    # A `sh` whose result is thrown away is the bug. Every one of these must be
    # captured into a variable the code then acts on.
    assert_includes guard_body, "_, fetched = sh", "the fetch result is captured"
    assert_includes guard_body, "_, merged = sh",  "the merge result is captured"
    assert_includes guard_body, "_, pushed = sh",  "the push result is captured"

    assert_operator guard_body.scan(/abort!/).size, :>=, 4,
                    "missing repo, failed fetch, conflict, failed push, and a failed read-back all abort"
  end

  # INVARIANT 4 — the guard asserts its EFFECT, not the push's exit status. A
  # successful push is not the same fact as `main` being contained.
  test "the merge-forward reads containment back after pushing" do
    push_at    = guard_body.index("HEAD:refs/heads/")
    readback   = guard_body.index("--is-ancestor", push_at.to_i)
    assert push_at, "the guard pushes by ref"
    assert readback, "after pushing, the guard re-reads containment instead of trusting the push"
    assert_includes guard_body, "did NOT take",
                    "a push that reported success but left main uncontained must still abort"
  end

  # A conflict must leave nothing half-merged for the next run to trip over.
  test "a merge conflict aborts the merge and pushes nothing" do
    conflict = guard_body[/unless merged.*?end/m]
    assert conflict, "the guard handles a failed merge"
    assert_includes conflict, "merge\", \"--abort\"",
                    "a conflicted merge is backed out of the workspace"
    assert_includes conflict, "abort!", "and the run stops"
  end
end
