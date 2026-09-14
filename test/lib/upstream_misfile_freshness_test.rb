# frozen_string_literal: true

# [integration] THE TREE THE AUDIT READS — the freshness guard in front of the
# upstream changelog detector (/tasks/audit-certifies-a-stale-tree), against real git.
#
# THE DEFECT THIS EXISTS FOR. bin/pr-review refreshed the gem's `accepted` before
# auditing it and DISCARDED the fetch's status. A stale remote-tracking ref still
# RESOLVES, so the audit never reached a skip branch: it read the PRE-merge tree,
# found nothing, and printed a confident clean — carrying a real, non-zero `judged`.
# That count is the detector's credibility device, the thing that makes "zero found"
# a measurement rather than a vacuum, so the failure did not merely lose a finding:
# it certified the WRONG TREE with a number. Every other give-up in the audit prints
# a named sentence; this was the one that did not.
#
# THE TRIGGER IS ROUTINE, not exotic — HTTPS remotes and an hourly GitHub App token.
# A stale token fails the fetch on an ordinary review.
#
# TWO CHECKS, AND EACH OWNS A FAILURE THE OTHER CANNOT SEE. Every test below names
# which one is biting, because that division of labour is the whole design:
#
#   FETCH STATUS  — the refresh that never landed (exit 128), and the PARTIAL refresh
#                   where a force-moved tag is refused (exit 1) while the branch
#                   updates anyway. Stale tags are a wrong baseline, and the ancestor
#                   check passes there, because the branch really did move.
#   IS-ANCESTOR   — a tree that does not carry the merge though the fetch exited 0.
#                   The property itself, rather than the mechanism that delivers it.
#
# REAL, not mocked: a local upstream, a clone taken before the merge, a real `git
# merge`, a real force-moved tag, a real broken remote. No network.
#
#   ruby -Itest test/lib/upstream_misfile_freshness_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../bin/lib/upstream_misfile"

class UpstreamMisfileFreshnessTest < Minitest::Test
  SHIPPED = "0.40.0"
  BASE = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- entry one\n\n" \
         "## 0.39.0 — 2026-08-11\n\n- older entry\n"

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')} failed in #{dir}:\n#{out}"
    out
  end

  def read(repo) = File.read(File.join(repo, "CHANGELOG.md"))

  def commit(repo, text, message)
    File.write(File.join(repo, "CHANGELOG.md"), text)
    git(repo, "add", "CHANGELOG.md")
    git(repo, "commit", "--quiet", "-m", message)
  end

  # The gem as GitHub holds it: `accepted` at the roll, tagged, nothing mis-filed yet.
  def upstream!(root)
    repo = File.join(root, "solana-studio-upstream")
    Open3.capture2e("git", "init", "--quiet", "-b", "accepted", repo)
    { "user.email" => "test@example.com", "user.name" => "Test",
      "commit.gpgsign" => "false", "tag.gpgsign" => "false" }.each { |k, v| git(repo, "config", k, v) }
    commit(repo, BASE, "base")
    @base = git(repo, "rev-parse", "HEAD").strip
    commit(repo, Release::Changelog.roll(read(repo), version: SHIPPED, date: "2026-09-14"), "Release #{SHIPPED}")
    git(repo, "tag", "-a", "v#{SHIPPED}", "-m", "Release solana-studio v#{SHIPPED}")
    repo
  end

  # THE SIBLING CHECKOUT bin/pr-review reads. Cloned BEFORE the review merge, so it
  # carries the tag (the audit has a baseline) and a pre-merge `origin/accepted`.
  def sibling!(root, upstream)
    repo = File.join(root, "solana-studio")
    Open3.capture2e("git", "clone", "--quiet", upstream, repo)
    git(repo, "config", "commit.gpgsign", "false")
    repo
  end

  # THE REVIEW MERGE THAT CREATES THE MISFILE: a branch forked BEFORE the roll writes
  # its bullet into `## Unreleased`, and merging it after the roll files that bullet
  # under a version that already shipped. Returns the merged head — the PR's head SHA,
  # which `--merge` leaves as an ancestor of `accepted`.
  def land_the_misfile!(upstream)
    git(upstream, "checkout", "--quiet", "-b", "feat/stale", @base)
    commit(upstream, read(upstream).sub("- entry one\n", "- entry one\n- entry two\n"), "a bullet into the bucket")
    head = git(upstream, "rev-parse", "HEAD").strip
    git(upstream, "checkout", "--quiet", "accepted")
    git(upstream, "merge", "--quiet", "--no-edit", "feat/stale")
    head
  end

  # The routine trigger, modelled without a network: a remote that cannot be reached
  # is the same exit shape as an expired token on an HTTPS remote.
  def break_remote!(repo, root)
    git(repo, "remote", "set-url", "origin", File.join(root, "no-such-remote"))
  end

  def fetch_exit(repo)
    Open3.capture3("git", "-C", repo, "fetch", "origin", "accepted", "--tags", "--quiet").last.exitstatus
  end

  def guard(repo, merged_head: nil)
    UpstreamMisfile.refresh_or_skip(path: repo, branch: "accepted", merged_head: merged_head)
  end

  def audit(repo) = UpstreamMisfile.audit(path: repo, rev: "origin/accepted")

  def with_pair
    Dir.mktmpdir("upstream-freshness") do |root|
      upstream = upstream!(root)
      yield root, upstream, sibling!(root, upstream)
    end
  end

  # THE BITE — FETCH STATUS. The merge landed upstream, the token aged out, and the
  # audit alone reports a confident clean on the tree it read an hour ago.
  def test_a_failed_fetch_skips_instead_of_certifying_the_pre_merge_tree
    with_pair do |root, upstream, sibling|
      merged_head = land_the_misfile!(upstream)
      break_remote!(sibling, root)

      # THE DEFECT, measured rather than described: the audit on its own does not skip
      # here — the stale ref resolves, so it judges real lines of the WRONG tree.
      stale = audit(sibling)
      refute stale.skipped?, "the stale tree resolves, so the audit never reaches a skip — that is the defect"
      refute stale.found?, "…and it finds nothing, because the merge is not in the tree it read"
      assert_operator stale.judged, :>, 0, "…while still reporting a real judged count, certifying the wrong tree"

      # THE GUARD: the fetch failed, so the tree is not the merge's and is not judged.
      skipped = guard(sibling, merged_head: merged_head)
      refute_nil skipped, "a failed fetch must produce a skip, never a clean verdict"
      assert skipped.skipped?
      assert_includes skipped.skipped, "could not refresh origin/accepted"
      assert_equal 0, skipped.judged, "a skip judges nothing, so no count can be read as a measurement"
      refute skipped.found?

      # …and the finding the false clean was hiding is really there once refreshed.
      git(sibling, "remote", "set-url", "origin", upstream)
      assert_nil guard(sibling, merged_head: merged_head), "a reachable remote carrying the merge is not skipped"
      assert audit(sibling).found?, "the misfile the stale read called clean"
    end
  end

  # FETCH STATUS owns this one ALONE. A force-moved tag is refused (exit 1) while the
  # branch updates anyway: the ancestor check passes, and the v* tags — this
  # detector's baseline for what SHIPPED — are left behind.
  def test_a_refused_tag_update_skips_even_though_the_branch_advanced
    with_pair do |_root, upstream, sibling|
      stale_tag = git(sibling, "rev-parse", "v#{SHIPPED}").strip
      merged_head = land_the_misfile!(upstream)
      git(upstream, "tag", "-f", "-a", "v#{SHIPPED}", "-m", "re-cut #{SHIPPED}")

      skipped = guard(sibling, merged_head: merged_head)

      refute_nil skipped, "a refused tag update leaves a stale baseline and must skip"
      assert_includes skipped.skipped, "v* tags may pre-date the release"
      # THE MEASURED ASYMMETRY. The fetch reports the refusal (exit 1 here), while the
      # branch advanced anyway — so the ancestor check alone would have passed this
      # tree and audited it against a baseline a release older than its own accepted.
      refute_equal 0, fetch_exit(sibling), "the fetch reports the refused tag update"
      ancestor = Open3.capture2e("git", "-C", sibling, "merge-base", "--is-ancestor",
                                 merged_head, "origin/accepted").last.success?
      assert ancestor, "the BRANCH did advance — which is exactly why the ancestor check cannot see this"
      assert_equal stale_tag, git(sibling, "rev-parse", "v#{SHIPPED}").strip,
                   "…while the tag the audit reads as its baseline never moved"
    end
  end

  # IS-ANCESTOR owns this one ALONE. The fetch succeeds, so the status check is
  # satisfied, and the tree still does not carry the merge.
  def test_a_tree_without_the_merged_head_skips_though_the_fetch_succeeded
    with_pair do |_root, _upstream, sibling|
      absent = "0" * 40

      skipped = guard(sibling, merged_head: absent)

      assert_equal 0, fetch_exit(sibling), "the refresh itself is clean, so only the ancestor check can bite"
      refute_nil skipped, "a tree that does not carry the merge must skip"
      assert_includes skipped.skipped, "does not carry the merged head"
      assert_includes skipped.skipped, absent[0, 7]
      assert_equal 0, skipped.judged
    end
  end

  # THE CONTROL that keeps the guard from becoming a blanket refusal: a refreshed tree
  # that really does carry the merge is not skipped, and the detector then runs.
  def test_a_refreshed_tree_carrying_the_merge_is_judged_not_skipped
    with_pair do |_root, upstream, sibling|
      merged_head = land_the_misfile!(upstream)

      assert_nil guard(sibling, merged_head: merged_head), "the honest path must not skip"

      result = audit(sibling)
      refute result.skipped?, "skipped: #{result.skipped}"
      assert result.found?, "and the detector reaches its finding: #{result.judged} judged"
      assert_equal ["- entry two"], result.findings.map { |m| m[:line].strip }
    end
  end

  # A BLANK head disables the ancestor check by design — not knowing the head is no
  # reason to stop judging a tree that refreshed cleanly — and the status check still
  # guards the failure that produced the false clean.
  def test_a_blank_merged_head_still_guards_on_the_fetch
    with_pair do |root, upstream, sibling|
      land_the_misfile!(upstream)

      assert_nil guard(sibling), "a clean refresh with an unknown head still judges"
      assert audit(sibling).found?, "…and the detector is not disabled by the missing head"

      break_remote!(sibling, root)
      skipped = guard(sibling)
      refute_nil skipped, "but a failed fetch skips whether or not the head is known"
      assert_includes skipped.skipped, "could not refresh"
    end
  end

  # A guard that cannot be read is still a skip, never a pass: the injected git is the
  # seam the unit side drives, and an exploding one must not certify anything.
  def test_a_git_that_raises_skips_rather_than_certifying
    exploding = ->(_args) { raise IOError, "git vanished" }

    skipped = UpstreamMisfile.refresh_or_skip(path: "/nowhere", branch: "accepted", git: exploding)

    refute_nil skipped
    assert_includes skipped.skipped, "could not be proven fresh"
    assert_equal 0, skipped.judged
  end

  # THE SEAM, pinned in source — bin/pr-review has no execution harness and the merge
  # it wraps is network. Two properties this task added, and one it must not have
  # broken: the refresh's verdict is READ rather than discarded, the merged head is
  # plumbed in from the merge that just landed, and the audit is STILL advisory —
  # `handed_off` is the verdict, so no freshness skip can fail a review.
  def test_pr_review_reads_the_refresh_verdict_and_the_audit_stays_advisory
    source = File.read(File.expand_path("../../bin/pr-review", __dir__))
    start = source.index(/^def report_upstream_changelog_misfile\(/)
    helper = source[start...(source.index(/^def /, start + 1) || source.length)]

    refute_match(/^\s*run_capture\(\[[^\n]*"fetch"/, helper,
                 "the bare fetch whose status was discarded must be gone")
    assert_match(/result\s*=\s*UpstreamMisfile\.refresh_or_skip\(/, helper,
                 "the refresh must report a verdict the audit path reads")
    assert_includes helper, "merged_head: merged_head", "and it must be told which merge to look for"
    assert_match(/def report_upstream_changelog_misfile\(pr_url, merged_head: nil\)/, helper)

    caller_start = source.index(/^def move_reviewed\(/)
    body = source[caller_start...(source.index(/^def /, caller_start + 1) || source.length)]
    assert_match(/report_upstream_changelog_misfile\([^\n]*merged_head: zap_head \|\| reviewed_head\)\n\s*handed_off\n/,
                 body, "the merged head comes from the merge that just landed, and the audit is NOT the verdict")
  end
end
