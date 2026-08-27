# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The reclaim sweep used to fetch every discovered repo with allow_fail and let
# git's stderr through. On a machine holding a RETIRED checkout — acquisition-
# studio, whose GitHub repo was deleted — every single run opened with
#
#   remote: Repository not found.
#   fatal: repository 'https://github.com/amcritchie/acquisition-studio.git/' not found
#
# non-fatally. The sweep was fine; the OUTPUT looked like a crash, and an operator
# reading the head of it cannot tell noise from failure.
#
# The second half matters more than the tidiness. Every reclaim signal is read
# against remote-tracking refs. If the fetch never happened those refs are STALE,
# and a desk judged "merged, safe to delete" on refs that stopped moving when the
# remote vanished is judged on evidence nobody refreshed.
class OriginUnreachableReclaimTest < ActiveSupport::TestCase
  def script
    @script ||= begin
      src = File.read(Rails.root.join("bin/agent-worktree")).sub(/^\s*main\b.*$/, "")
      host = Object.new
      host.instance_eval(src, "bin/agent-worktree")
      host
    end
  end

  # Both memos, not just the failures one. ORIGIN_CHECKED records "did we already ask
  # about this repo", so a leftover entry would make refresh_origin_reachability! skip
  # the fetch and silently weaken any test that drives it.
  def setup
    script.singleton_class.const_get(:ORIGIN_UNREACHABLE).clear
    script.singleton_class.const_get(:ORIGIN_CHECKED).clear
  rescue NameError
    nil
  end

  def record_for(repo)
    { app: { "slug" => "retired", "repo" => repo }, task: "some-desk" }
  end

  # ---- classifying the failure -------------------------------------------
  #
  # VERBATIM stderr, captured from this machine on 2026-08-25. Tested as strings
  # rather than by fetching a real remote: a network call here would be slow and
  # flaky, and the thing under test is the CLASSIFICATION, not git.

  DELETED_REMOTE = <<~ERR
    remote: Repository not found.
    fatal: repository 'https://github.com/amcritchie/acquisition-studio.git/' not found
  ERR

  UNREADABLE_REMOTE = <<~ERR
    fatal: '/nonexistent/path/to/repo.git' does not appear to be a git repository
    fatal: Could not read from remote repository.
  ERR

  test "a deleted remote is classified gone" do
    assert script.origin_gone?(DELETED_REMOTE),
           "the verbatim stderr of a deleted GitHub repo must classify as gone"
  end

  # An unreadable remote is NOT gone. Both withhold, but they earn different words
  # to the operator, and calling a dead network 'this repo was deleted' is a lie
  # that would send someone looking for a repo that is fine.
  test "an unreadable remote is not classified gone" do
    refute script.origin_gone?(UNREADABLE_REMOTE)
  end

  test "clean fetch output is never classified gone" do
    refute script.origin_gone?("")
    refute script.origin_gone?(nil)
  end

  # WIRING, and the bug this file exists to keep out. capture_status returns
  # stdout and stderr SEPARATELY, and git writes "remote: Repository not found."
  # to STDERR — so a first cut that classified on stdout alone read every deleted
  # remote as a generic error. The pure test above could not catch it: it is
  # handed a string, so it proves the CLASSIFIER and says nothing about which
  # stream reaches it. Only a real fetch does.
  #
  # An ext:: remote pointed at a script gives a real git fetch that fails with a
  # chosen message on a chosen stream, with no network involved.
  test "a real fetch failure is classified from stderr, not stdout alone" do
    Dir.mktmpdir do |repo|
      helper = File.join(repo, "fake-remote.sh")
      File.write(helper, %(#!/bin/sh
echo "remote: Repository not found." >&2
exit 1
))
      FileUtils.chmod(0o755, helper)

      system("git", "init", "-q", repo, exception: true)
      system("git", "-C", repo, "config", "protocol.ext.allow", "always", exception: true)
      system("git", "-C", repo, "remote", "add", "origin", "ext::#{helper}", exception: true)

      assert_equal :gone, script.origin_fetch_status(repo),
                   "the deleted-remote marker arrives on STDERR; classifying stdout alone misses it"
    end
  end

  # ---- the safety property ------------------------------------------------

  test "a desk whose origin is gone is withheld, with the reason named" do
    script.singleton_class.const_get(:ORIGIN_UNREACHABLE)["/projects/retired"] = :gone

    hold = script.origin_hold(record_for("/projects/retired"))

    refute_nil hold, "a desk whose origin no longer exists was NOT withheld"
    assert_includes hold, "no longer exists"
    assert_includes hold, "provably reclaimable"
  end

  test "a desk whose origin was merely unreachable is withheld for stale evidence" do
    script.singleton_class.const_get(:ORIGIN_UNREACHABLE)["/projects/offline"] = :error

    hold = script.origin_hold(record_for("/projects/offline"))

    refute_nil hold
    assert_includes hold, "stale evidence is not permission to delete"
  end

  # THE OTHER HALF. This guard must not withhold everything — a healthy repo has
  # to stay reclaimable, or the sweep quietly stops doing its job.
  test "a repo whose origin fetched cleanly is not withheld by this guard" do
    assert_nil script.origin_hold(record_for("/projects/healthy")),
               "a healthy repo was withheld — the guard is over-broad and the sweep would never reclaim"
  end

  test "a record with no app hash is not withheld by this guard" do
    assert_nil script.origin_hold({ app: nil, task: "x" }),
               "a malformed record must fall through to the other holds, not crash or auto-withhold here"
  end

  # WIRING, asserted structurally. A guard that is never called is the same as no
  # guard, and every other test here calls origin_hold DIRECTLY — so all of them
  # would stay green if it were dropped from the chain. reclaim_hold is the one
  # chokepoint the sweep, the under-lock re-verify, doctor and the registry
  # snapshot all route through, and origin_hold must come FIRST: the holds after
  # it read remote-tracking refs, which is exactly what a failed fetch left stale.
  test "origin_hold is the first link in the reclaim_hold chain" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    chain = src[/def reclaim_hold.*?\nend/m]

    refute_nil chain, "reclaim_hold could not be located — this test must be re-pointed, not deleted"
    assert_includes chain, "origin_hold(record)",
                    "origin_hold was dropped from the reclaim chain; the guard is dead code"
    # Anchored on the newline: "reclaim_hold(" CONTAINS "claim_hold(", so an
    # unanchored index matched the method name itself and this assertion compared
    # a position against the signature it lives in.
    assert_operator chain.index("origin_hold(record)"), :<, chain.index("\n    claim_hold("),
                    "origin_hold must run BEFORE the holds that read remote-tracking refs"
  end
end
