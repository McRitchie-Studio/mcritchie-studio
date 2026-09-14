# frozen_string_literal: true

# [integration] The UPSTREAM changelog misfile — an ABSOLUTE state check of one
# tree, against real git (/tasks/detect-upstream-changelog-misfiles).
#
# THE HAZARD, and why it needs a SECOND reader rather than a wider first one.
# bin/release.rb's refuse_misfiled_changelog! is DIFFERENTIAL by construction: it
# predicts the promote with `git merge-tree` and compares the result against the two
# sides, so it can only ever see a line ONE side brought. A branch that forks BEFORE
# `accepted` absorbs a roll, keeps writing bullets into its own `## Unreleased` and is
# merged AFTER puts those bullets inside a version section that already shipped — and
# from then on BOTH sides carry them, the diff shows nothing, and the guard reads it
# as an ordinary post-release edit. test_the_differential_guard_is_blind_to_it below
# asserts that blindness on the very tree this detector catches, so the two readers'
# division of labour is a measured fact and not a claim in a comment.
#
# THE MERGE THAT CREATES IT IS THE REVIEW MERGE (feat → accepted), not the promote —
# which is why the detector is wired into bin/pr-review's post-merge step and not
# beside its differential sibling in bin/release prepare.
#
# REAL, not mocked: a bare origin, a clone, an `accepted` that absorbed the roll and
# was tagged, a branch forked before it, and a real `git merge`. No network.
#
#   ruby -Itest test/lib/release_changelog_upstream_misfile_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../bin/lib/upstream_misfile"

class ReleaseChangelogUpstreamMisfileTest < Minitest::Test
  SHIPPED = "0.40.0"
  BASE = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- entry one\n\n" \
         "## 0.39.0 — 2026-08-11\n\n- older entry\n"

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    assert status.success?, "git #{args.join(' ')} failed in #{dir}:\n#{out}"
    out
  end

  def write(repo, text)
    File.write(File.join(repo, "CHANGELOG.md"), text)
  end

  def commit(repo, text, message)
    write(repo, text)
    git(repo, "add", "CHANGELOG.md")
    git(repo, "commit", "--quiet", "-m", message)
  end

  def read(repo) = File.read(File.join(repo, "CHANGELOG.md"))

  # A repo with `accepted` at BASE and nothing shipped yet.
  def init(root)
    repo = File.join(root, "studio-engine")
    Open3.capture2e("git", "init", "--quiet", "-b", "accepted", repo)
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "config", "tag.gpgsign", "false")
    commit(repo, BASE, "base")
    repo
  end

  # The roll `bin/release prepare` writes onto `accepted`, plus the tag the publish
  # leaves on it — the state every branch forked after this point inherits.
  def roll!(repo, version = SHIPPED)
    commit(repo, Release::Changelog.roll(read(repo), version: version, date: "2026-09-14"), "Release #{version}")
    git(repo, "tag", "-a", "v#{version}", "-m", "Release studio-engine v#{version}")
  end

  # A branch forked at `from` whose commit rewrites CHANGELOG.md, and the review merge
  # (feat → accepted) that lands it.
  def merge_branch(repo, from, message: "write a bullet into the bucket")
    git(repo, "checkout", "--quiet", "-b", "feat/stale", from)
    commit(repo, yield(read(repo)), message)
    git(repo, "checkout", "--quiet", "accepted")
    git(repo, "merge", "--quiet", "--no-edit", "feat/stale")
  end

  # The bullet a PRE-ROLL fork writes: inside the bucket's existing `### Fixed`
  # subsection, the shape that merges CLEAN rather than conflicting. On that branch
  # `- entry one` still sits under `## Unreleased`; on `accepted` the roll has already
  # moved it under the version heading, which is how the merge mis-files it.
  def stale_fork_bullet(text) = text.sub("- entry one\n", "- entry one\n- entry two\n")

  # The same bullet from a POST-ROLL fork, which sees the emptied bucket and opens a
  # fresh subsection inside it.
  def fresh_fork_bullet(text) = text.sub("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- entry two\n")

  def audit(repo) = UpstreamMisfile.audit(path: repo, rev: "accepted")

  def with_repo
    Dir.mktmpdir("upstream-misfile") { |root| yield init(root) }
  end

  # THE BITE. The branch forked BEFORE the roll, so its bullet was written under
  # `## Unreleased` and the merge filed it under a version that already shipped.
  def test_a_bullet_from_a_pre_roll_fork_merged_after_the_roll_is_detected
    with_repo do |repo|
      base = git(repo, "rev-parse", "HEAD").strip
      roll!(repo)
      merge_branch(repo, base) { |text| stale_fork_bullet(text) }

      result = audit(repo)

      refute result.skipped?, "the detector must run, not skip: #{result.skipped}"
      assert result.found?, "the misfile must be detected — judged #{result.judged} line(s)\n#{read(repo)}"
      assert_equal [SHIPPED], result.findings.map { |m| m[:version] }.uniq
      assert_equal ["- entry two"], result.findings.map { |m| m[:line].strip }
      assert_includes result.notice, "- entry two"
      assert_includes result.notice, SHIPPED
      assert_includes result.notice, "UPSTREAM misfile"
      assert_includes result.notice, "## Unreleased"
    end
  end

  # THE POINT OF THE SECOND READER. On the SAME tree, the differential guard that
  # already ships sees nothing — the line is under a shipped heading on both sides of
  # every merge it will ever predict, so no diff can show it.
  def test_the_differential_guard_is_blind_to_it
    with_repo do |repo|
      base = git(repo, "rev-parse", "HEAD").strip
      roll!(repo)
      rolled = read(repo)
      merge_branch(repo, base) { |text| stale_fork_bullet(text) }
      misfiled = read(repo)

      # The promote it would judge: `release` sits at the roll, `accepted` carries the
      # misfile, and the merge of the two is `accepted`'s file.
      refusal = Release::Changelog.misfile_refusal(misfiled, base: rolled, sides: [rolled, misfiled],
                                                   published: [SHIPPED])
      assert_nil refusal, "the differential guard must be blind here — that is why this detector exists"

      # And once the promote lands, both sides carry it, so it stays blind forever.
      assert_nil Release::Changelog.misfile_refusal(misfiled, base: misfiled, sides: [misfiled, misfiled],
                                                   published: [SHIPPED])
      assert audit(repo).found?, "…while the absolute check still sees it"
    end
  end

  # CONTROL 1 — the same bullet from a branch forked AFTER the roll lands under
  # `## Unreleased`, which is correct filing. Nothing to report.
  def test_a_bullet_from_a_post_roll_fork_is_filed_correctly
    with_repo do |repo|
      roll!(repo)
      merge_branch(repo, "accepted") { |text| fresh_fork_bullet(text) }

      result = audit(repo)

      refute result.skipped?, "skipped: #{result.skipped}"
      refute result.found?, "a bullet under '## Unreleased' is not mis-filed: #{result.notice}"
      assert_includes Release::Changelog.unreleased_entries(read(repo)), "- entry two"
    end
  end

  # CONTROL 2 — REWORDING, the population that made the naive form of this question
  # unusable (158 lines in studio-engine, measured 2026-09-14). The edit post-dates
  # the tag exactly like a misfile does, and the detector judges it and stays silent,
  # because its author wrote it under the VERSION heading rather than the bucket.
  def test_a_shipped_section_reworded_after_release_is_not_a_misfile
    with_repo do |repo|
      roll!(repo)
      commit(repo, read(repo).sub("- entry one\n", "- entry one, clarified after release\n"), "reword 0.40.0")

      result = audit(repo)

      refute result.skipped?, "skipped: #{result.skipped}"
      refute result.found?, "a post-release reword is legitimate: #{result.notice}"
      # …and it really was in the population: the naive question would have flagged it.
      judged = Release::Changelog.upstream_judged_entries(
        read(repo), published: [SHIPPED], at_tag: ->(v) { git(repo, "show", "v#{v}:CHANGELOG.md") }
      )
      reworded = judged.find { |e| e[:line].include?("clarified after release") }
      assert reworded, "the reworded line must be judged, not skipped"
      refute reworded[:baseline].key?(reworded[:line].rstrip), "and it must post-date the tag"
    end
  end

  # CONTROL 3 — BACKFILL, the other population: the documented remedy for a backlog
  # inserts a version heading ABOVE entries written under `## Unreleased` long before.
  # Those entries pre-date their heading by design, so the tag's file is no baseline
  # and the section is not judged at all.
  def test_a_heading_backfilled_above_older_entries_is_not_judged
    with_repo do |repo|
      # Shipped with the entries still sitting under `## Unreleased` — the backlog.
      git(repo, "tag", "-a", "v#{SHIPPED}", "-m", "Release studio-engine v#{SHIPPED}")
      # …then attributed to their real version afterwards.
      commit(repo, read(repo).sub("## Unreleased\n", "## Unreleased\n\n## #{SHIPPED} — 2026-09-14\n"),
             "attribute the backlog to #{SHIPPED}")

      result = audit(repo)

      refute result.skipped?, "skipped: #{result.skipped}"
      refute result.found?, "a backfilled heading has no honest baseline: #{result.notice}"
      assert_equal 0, result.judged, "so the section is not judged at all"
    end
  end

  # A repo with nothing tagged has no definition of "shipped": the detector says so
  # instead of returning a clean verdict it did not earn.
  def test_an_untagged_repo_is_skipped_by_name
    with_repo do |repo|
      result = audit(repo)

      assert result.skipped?, "an untagged repo must skip, not pass"
      assert_includes result.skipped, "no v* tag"
      refute result.found?
    end
  end

  # An in-flight version — heading written, nothing published under it yet — ships
  # WITH whatever sits under it, so it is correct filing and is not judged.
  def test_an_untagged_heading_is_not_judged
    with_repo do |repo|
      base = git(repo, "rev-parse", "HEAD").strip
      roll!(repo)
      git(repo, "tag", "--delete", "v#{SHIPPED}")
      git(repo, "tag", "-a", "v0.39.0", "-m", "Release studio-engine v0.39.0")
      merge_branch(repo, base) { |text| stale_fork_bullet(text) }

      result = audit(repo)

      refute result.skipped?, "skipped: #{result.skipped}"
      refute result.found?, "an unpublished version ships with its entries: #{result.notice}"
    end
  end
# THE SEAM, pinned in source — bin/pr-review has no execution harness and the merge
# it wraps is network. Three properties, and each is a decision this task made:
# the detector runs INSIDE the merge-ready handoff (the review merge is where the
# misfile is created), AFTER the merge (the state does not exist before it), and it
# is NOT the verdict — `handed_off` is, so a finding can never fail a review.
def test_pr_review_runs_the_detector_after_the_merge_and_never_gates_on_it
  source = File.read(File.expand_path("../../bin/pr-review", __dir__))
  start = source.index(/^def move_reviewed\(/)
  body = source[start...(source.index(/^def /, start + 1) || source.length)]

  merge_at = body.index("merge_feature_pr(")
  audit_at = body.index("report_upstream_changelog_misfile(")
  assert merge_at, "move_reviewed must merge the feat PR"
  assert audit_at, "and must run the upstream changelog detector"
  assert_operator merge_at, :<, audit_at, "the detector runs AFTER the merge that creates the misfile"
  assert_match(/report_upstream_changelog_misfile\([^\n]*\)\n\s*handed_off\n/, body,
               "and its result must not be the verdict")

  helper = source[source.index("def report_upstream_changelog_misfile(")..][0, 1600]
  assert_includes helper, "GEM_REPOS.include?(repo)", "only a registered gem's CHANGELOG is rolled"
  assert_includes helper, "ACCEPTED_BRANCH", "and the tree it reads is the gem's `accepted`"
  assert_includes helper, "SKIPPED", "every give-up prints its reason rather than passing quietly"
end
end
