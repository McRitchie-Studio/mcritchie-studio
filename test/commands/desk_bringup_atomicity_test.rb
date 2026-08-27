# frozen_string_literal: true

require "test_helper"

# [unit] `bin/agent-worktree new` must be ATOMIC — a whole desk, or nothing.
#
# THE DEFECT. `new` is a SEQUENCE: cut the git worktree, allocate a port and a
# Redis DB into a stack env, write the context marker, provision the test DB. Any
# step can fail — a taken port, a full Redis band, an abort inside sh, a raise, a
# Ctrl-C — and every earlier step stayed on disk. What was left was a HALF-BUILT
# DESK: a checkout with a branch and no env, or an env holding a port and a Redis
# DB that nothing would ever release. Those leak silently, because a desk that
# looks real is never swept.
#
# Re-homed from PR #550, which sat open and unowned for six weeks. That branch is
# 1293 commits behind accepted and spans 16 files including bin/release.rb,
# bin/fast-check and the release gate models — concerns since superseded. Only the
# ATOMICITY intent is carried here, re-implemented against current code.
class DeskBringupAtomicityTest < ActiveSupport::TestCase
  def script
    @script ||= begin
      src = File.read(Rails.root.join("bin/agent-worktree")).sub(/^\s*main\b.*$/, "")
      host = Object.new
      host.instance_eval(src, "bin/agent-worktree")
      host
    end
  end

  def unwinder = script.singleton_class.const_get(:DeskUnwinder).new

  test "undos run in REVERSE, so each step unwinds into the state before it" do
    order = []
    u = unwinder
    u.on_success("first")  { order << :first }
    u.on_success("second") { order << :second }
    u.on_success("third")  { order << :third }

    capture_io { u.unwind! }

    assert_equal %i[third second first], order,
                 "undos ran forwards; a later step's undo can depend on an earlier one still " \
                 "being in place, so reverse order is the whole contract"
  end

  # A ROLLBACK THAT RAISES leaves exactly the mess it was called to prevent, AND
  # masks the original failure — which is the thing the operator needs to read.
  test "a failing undo does not stop the ones behind it" do
    reached = []
    u = unwinder
    u.on_success("innermost") { reached << :innermost }
    u.on_success("explodes")  { raise IOError, "disk gone" }
    u.on_success("outermost") { reached << :outermost }

    out, _err = capture_io { u.unwind! }

    assert_equal %i[outermost innermost], reached,
                 "one exploding undo aborted the rollback — the earlier steps stayed on disk"
    assert_match(/unwind FAILED for explodes/, out + _err,
                 "the failed undo must be REPORTED, not silently skipped")
  end

  test "committing discards the undos so a successful bringup keeps its desk" do
    ran = []
    u = unwinder
    u.on_success("would delete the desk") { ran << :deleted }

    u.commit!
    capture_io { u.unwind! }

    assert_empty ran, "a committed bringup still unwound — a successful `new` would delete itself"
  end

  # THE WIRING. Every behavioural test above drives DeskUnwinder directly, so all
  # of them would stay green if `new` never used it. This asserts the sequence is
  # actually wrapped, and that the three steps that leak register an undo.
  test "the new command wraps its bringup and registers an undo per step" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/when "new"(.*?)when "/m, 1]

    refute_nil body, "the `new` dispatch moved — re-point this test rather than deleting it"
    assert_includes body, "DeskUnwinder.new", "`new` does not use the unwinder at all"
    assert_match(/unwinder\.on_success\("git worktree/, body,
                 "a failed bringup would leave the checkout and its branch behind")
    assert_match(/unwinder\.on_success\("stack env/, body,
                 "a failed bringup would leave an env holding a port and a Redis DB that nothing " \
                 "ever releases")
    assert_match(/unwinder\.unwind!/, body, "nothing ever triggers the rollback")
    assert_match(/unwinder\.commit!/, body,
                 "without a commit, a SUCCESSFUL new would unwind its own desk")
  end

  # NOT OURS TO DESTROY. Re-running `new` over an existing desk must repair it,
  # never delete it — the undos are registered only for what THIS run created.
  test "an existing desk registers no undo" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/when "new"(.*?)when "/m, 1]

    assert_match(/unless pre_existing/, body,
                 "re-running new over an existing desk would register an undo that could DELETE " \
                 "someone else's live work on the next failure")
    assert_match(/unless env_pre_existing/, body)
  end
end
