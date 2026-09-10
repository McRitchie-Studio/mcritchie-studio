# frozen_string_literal: true

require "time"
require_relative "fast_cert"

# COULD THIS GREEN HAVE COVERED THIS MERGE?
#
# ReviewTreeGuard.base_assessment (SEAM 2) answers "has the base moved?" and REPORTS it.
# This module answers the question a reviewer is left holding after that report, and it
# is a different question: of the movement the base gained, WHICH PART landed after the
# run finished, and does any of it grade the code this PR changes?
#
# ── THE HOLE THIS EXISTS FOR ─────────────────────────────────────────────────────
#
# A PR's CI runs against the base AS IT STOOD when the run started. ci.yml triggers on
# pull_request and on pushes to main, release AND `accepted` (.github/workflows/ci.yml,
# `push: branches:` — `accepted` has been in that list since 2026-08-14, ecd0ffe8). So a
# merge into `accepted` DOES start a run. THAT RUN IS NOT THIS ONE, and the distinction
# is the whole subject:
#
#   what the `accepted` push run grades — the `accepted` TIP. A tree this PR is not in.
#   what this PR's own green grades ---- its HEAD COMMIT, against the base as it stood
#                                        when the run started.
#   what actually ships ---------------- this PR MERGED ONTO the new tip. No trigger
#                                        exists that runs that combination, so it is the
#                                        one tree nobody executed.
#
# The green stays green while the tree it described stops being the tree the merge would
# produce. Stated this way ON PURPOSE: an earlier wording here claimed ci.yml ran "on
# pushes to main/release only, so nothing re-ran", and a reviewer can disprove that in
# one `sed -n 26,27p .github/workflows/ci.yml`. A gate whose reviewer-facing text asserts
# something false is a gate reviewers learn to route around — and the true argument is
# strictly stronger, because it survives the objection "but I can see the run".
#
# MEASURED (Carl, PR #1258, 2026-09-07): the `accepted` tip was committed at 07:59:02Z,
# 3.3 minutes AFTER that PR's CI completed at 07:55:44Z, and the commit it carried
# changed test/lib/dor_check_exempt_ci_test.rb by +117/-17 — the very guard that PR's
# design depended on. A 12/12 green said nothing whatever about the combination. It came
# out safe only because a reviewer built the merge preview by hand and ran the family.
#
# ── THE DISTINCTION THIS MODULE EXISTS TO PRESERVE ───────────────────────────────
#
# Reviewers satisfy the base-moved report by arguing FILE DISJOINTNESS: "the N commits
# `accepted` gained touch none of my files." That argument is cheap, and it is usually
# right. IT IS NOT THE CLAIM "THE MERGED TREE IS GREEN." The two come apart in exactly
# one shape, and it is the shape that was measured:
#
#   SHARED SOURCE — the base changed a file this PR also changes.
#                   Disjointness FAILS loudly. Reviewers already catch this, and the
#                   overlap machinery already reports it. NOT this module's subject.
#
#   SHARED GUARD  — the base changed a TEST that grades a file this PR changes, and
#                   this PR does not touch that test.
#                   Disjointness is TRUE AND IRRELEVANT. Nothing caught this.
#
# So the set this module intersects is NOT "base files ∩ PR files" (that is
# disjointness, and it is somebody else's check). It is "base files ∩ the tests that
# GRADE the PR's files, minus the PR's own files". Collapsing those two sets would
# reproduce the defect one level down, which is why they are named apart here and in
# every string the gate prints.
#
# ── WHY THE PAIRING IS THE NARROW ONE ────────────────────────────────────────────
#
# FastCert already encodes test↔subject pairing three ways: CONVENTION (the twin),
# FAMILY (a tool's test/lib/<stem>_<aspect>_test.rb siblings — the hop that names
# dor_check_exempt_ci_test.rb as bin/dor-check's), and a GREP fallback over token
# identity. This module uses CONVENTION + FAMILY ONLY and deliberately drops the grep
# fallback, because the two have different error directions and only one of them can be
# allowed to REFUSE:
#
#   convention + family — a structural claim about names, re-derivable by hand in one
#                         `ls`. A reviewer can check the refusal in seconds.
#   grep fallback       — a token search that widens to whatever mentions the subject.
#                         Wrong here in the expensive direction: it would refuse reviews
#                         over an incidental mention, and "the gate refused and I cannot
#                         see why" is how a gate gets routed around.
#
# The cost of that narrowing is stated plainly: a guard whose name does not follow the
# convention is NOT found, and this module stays silent about it. That is the SAME
# outcome as before this module existed, so the narrowing can only fail toward the
# status quo — never toward a refusal nobody can check, and never toward a green that
# is newly credited.
#
# ── DIRECTION OF ERROR, EVERYWHERE ───────────────────────────────────────────────
#
# Every unreadable input (no clock, an unparseable stamp, an unreadable ref, git
# failing) resolves to "the question could not be asked" — NEVER to "the base movement
# is fine". The caller reports the unmade check rather than refusing on it, for the same
# reason ReviewTreeGuard refuses to print :no_movement_seen as freshness: a gate that
# reports what it could not check as though it had checked it is the defect, one level
# down.
module BaseMovementAudit
  module_function

  # The audit. Returns a hash whose :state is one of:
  #   :no_movement  — the branch has every commit the base has (as this checkout sees it)
  #   :unobservable — a ref or the git read failed; the question could not be asked
  #   :moved        — the base gained commits, described below
  #
  # On :moved:
  #   :commits  — [{ sha:, at:, subject: }], oldest first, that the branch has not taken
  #   :files    — every file the base gained across all of them
  #   :clock    — :merge_ref when ancestry against the TESTED base answered (exact);
  #               :read when only the run's completion time parsed; else :unreadable
  #   :window   — :exact on :merge_ref; :unchecked otherwise — the mid-run window (base
  #               commits landing after the merge ref was built, before the run ended)
  #               was NOT asked, and the caller must say so
  #   :tested_base — the base SHA the tested merge ref was built on, when resolved
  #   :late     — on :merge_ref, the subset of :commits NOT in the tested base; on :read,
  #               those committed AFTER the run completed (a LOWER bound — sound when it
  #               finds something, blind to the mid-run window); [] when :unreadable
  #   :late_files — files carried by those commits ONLY, i.e. what CI provably never saw
  #   :guards   — [{ test:, guarding: [...] }] — the SHARED-GUARD intersection: a file in
  #               :late_files that grades a file this PR changes and that this PR does
  #               not itself change. NON-EMPTY IS THE REFUSABLE SHAPE.
  #
  # `changed_files` is the PR's own diff. `ci_completed_at` is when the run finished.
  # `tested_base` is the base SHA the run's merge ref was built on (MergeRefBase), or nil.
  #
  # WHY ANCESTRY, NOT A BETTER CLOCK (/tasks/stale-merge-ref-passes-freshness). The run
  # tested the merge ref GitHub built when it was TRIGGERED; completion is minutes later,
  # so a completion clock calls every commit landing inside the run "covered" — measured
  # on tm#682, where two merges landed mid-run and the gate passed. Swapping in the start
  # time would only shrink that window, and committer dates are not landing order anyway.
  # "Is this commit an ancestor of the base the merge ref was built on?" has no window.
  def assess(root:, branch:, base:, changed_files:, ci_completed_at:, tested_base: nil)
    base_sha = rev(root, "origin/#{base}", base)
    head_sha = rev(root, "origin/#{branch}", branch)
    return { state: :unobservable, reason: :no_ref } if base_sha.nil? || head_sha.nil?

    fork_point = merge_base(root, head_sha, base_sha)
    return { state: :unobservable, reason: :no_merge_base } if fork_point.nil?
    return { state: :no_movement } if fork_point == base_sha

    commits = commits_between(root, fork_point, base_sha)
    return { state: :unobservable, reason: :no_log } if commits.nil? || commits.empty?

    cutoff = parse_time(ci_completed_at)
    tested = tested_base.to_s.strip
    exact = !tested.empty? && commit?(root, tested)
    if exact
      clock = :merge_ref
      late = commits.reject { |c| ancestor?(root, c[:sha], tested) }
    else
      # The completion clock stays as a LOWER BOUND: anything it flags truly landed after
      # the run, so its refusals are sound (the PR #1258 shape). What it cannot do is call
      # anything COVERED, and :window :unchecked is how the caller learns that.
      clock = cutoff ? :read : :unreadable
      late = cutoff ? commits.select { |c| c[:time] && c[:time] > cutoff } : []
    end

    # The files CI provably never saw: everything between the newest commit it COULD
    # have seen and the base tip. A two-point diff rather than a per-commit walk, so a
    # MERGE commit (which is how `accepted` actually advances, and whose --name-only is
    # empty by default) contributes its files like any other.
    covered_tip = late.empty? ? base_sha : (commits - late).last&.dig(:sha) || fork_point
    late_files = late.empty? ? [] : diff_files(root, covered_tip, base_sha)

    {
      state: :moved,
      base_sha: base_sha, head_sha: head_sha, fork_point: fork_point,
      commits: commits.map { |c| c.reject { |k, _| k == :time } },
      files: diff_files(root, fork_point, base_sha),
      clock: clock, cutoff: cutoff,
      window: exact ? :exact : :unchecked,
      tested_base: exact ? tested : nil,
      window_reason: exact || tested.empty? ? nil : :not_local,
      late: late.map { |c| c.reject { |k, _| k == :time } },
      late_files: late_files,
      guards: shared_guards(root, changed_files, late_files)
    }
  rescue SystemCallError, IOError
    { state: :unobservable, reason: :git_unreadable }
  end

  # THE INTERSECTION THAT IS NOT DISJOINTNESS.
  #
  # For each file the PR changes, the tests that GRADE it (convention twin + harness
  # family — see the header for why the grep rung is excluded). A late base file lands
  # here when it is one of those tests AND the PR does not change it itself: a file the
  # PR also changes is the shared-SOURCE shape, which disjointness already catches and
  # which is somebody else's report.
  def shared_guards(root, changed_files, late_files)
    changed = Array(changed_files).map(&:to_s).reject(&:empty?).uniq
    late = Array(late_files).map(&:to_s).reject(&:empty?).uniq
    return [] if changed.empty? || late.empty?

    hits = Hash.new { |h, k| h[k] = [] }
    changed.each do |path|
      guards_for(root, path).each do |test|
        next unless late.include?(test)
        next if changed.include?(test) # shared SOURCE, not shared GUARD

        hits[test] << path
      end
    end
    hits.map { |test, guarding| { test: test, guarding: guarding.uniq.sort } }
        .sort_by { |g| g[:test] }
  end

  # The tests that grade one source file, by NAME convention only. Mirrors the first
  # branch of FastCert.mapping (convention twins that EXIST, plus the harness family)
  # and stops there — no orphan hop, no grep fallback.
  #
  # ONE BOUNDARY IS DELIBERATELY LEFT QUIET, and it is worth naming because a mutation
  # of the existence filter survives the suite. A source with NO twin on disk returns []
  # here, so a base commit that CREATES that twin after the run is not reported. Dropping
  # the filter would report it — arguably correctly, since a new test for this PR's code
  # is a guard CI never ran. It is left out because "the twin did not exist" is also how
  # a source with no tests at all reads, and this module refuses to distinguish those two
  # on a filename alone. The silence costs nothing beyond the status quo; guessing would
  # cost a refusal nobody can check.
  #
  # THE COST IS LARGER THAN THAT PARAGRAPH ADMITS, and under-disclosing it is its own
  # defect. `return [] if targets.empty?` does not merely skip the missing twin — it
  # returns BEFORE `family_tests`, so a tool whose twin is absent has NO guards at all
  # here, siblings included.
  #
  # MEASURED ACROSS THE WHOLE TREE, 2026-09-07 (not a sampled anecdote — the population,
  # via FastCert.convention_candidates over bin/* + bin/lib/*.rb):
  #
  #   137 tools/libs   90 have a twin and are covered   47 ARE INVISIBLE
  #   of those 47, SEVENTEEN have sibling tests sitting right there, discarded:
  #
  #     bin/release      → test/lib/release_test.rb       MISSING → 23 siblings dropped
  #     bin/task         → test/lib/task_test.rb          MISSING →  9 siblings dropped
  #     bin/devops-shift → test/lib/devops_shift_test.rb  MISSING →  4 siblings dropped
  #     bin/pr-review    → test/lib/pr_review_test.rb     MISSING →  2 siblings dropped
  #     …plus 13 more with 1-2 each.
  #
  # So a base commit rewriting release_ladder_test.rb while a bin/release PR is in
  # review produces NO finding. That is a third of this repo's tooling, not a corner.
  #
  # THIS FILE'S OWN NEIGHBOUR IS ONE OF THEM, which is the honest way to read the
  # number: bin/lib/ci_gate.rb has no test/lib/ci_gate_test.rb, so it is invisible here
  # too — and it is graded in practice by dor_check_exempt_ci_test.rb and
  # dor_check_base_movement_test.rb, whose stems the family hop would not reach even if
  # the early return were removed. The PR that introduced this paragraph changed
  # ci_gate.rb, so this audit could not have protected its own diff.
  #
  # bin/dor-check's twin EXISTS, which is the only reason the measured incident
  # (PR #1258) was caught — the audit's headline success is a property of that one
  # filename, not of the design.
  #
  # Still left as-is, for the reason above (the two readings of an absent twin are not
  # separable by filename), but the reader is now told WHICH tools that silence covers
  # rather than being left to infer it is a corner case. Widening it is a task, not a
  # comment: it needs a rule that distinguishes "untested" from "tested unconventionally"
  # without manufacturing refusals nobody can check.
  def guards_for(root, path)
    targets = FastCert.convention_candidates(path).select { |t| File.file?(File.join(root.to_s, t)) }
    return [] if targets.empty?

    (targets + FastCert.family_tests(root, path, targets)).uniq
  end

  # --- git reads (never fetches — same rule as ReviewTreeGuard) -------------------

  def commit?(root, sha)
    system("git", "-C", root.to_s, "cat-file", "-e", "#{sha}^{commit}", out: File::NULL, err: File::NULL)
  end

  # Is `sha` the tested base or reachable from it — i.e. was it in the tree CI tested?
  def ancestor?(root, sha, tested)
    system("git", "-C", root.to_s, "merge-base", "--is-ancestor", sha, tested,
           out: File::NULL, err: File::NULL)
  end

  def rev(root, *refs)
    refs.flatten.compact.map(&:to_s).reject(&:empty?).each do |ref|
      out = IO.popen(["git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}"],
                     err: File::NULL, &:read)
      next unless $?.success?

      sha = out.to_s.strip
      return sha unless sha.empty?
    end
    nil
  end

  def merge_base(root, one, two)
    out = IO.popen(["git", "-C", root.to_s, "merge-base", one, two], err: File::NULL, &:read)
    return nil unless $?.success?

    sha = out.to_s.strip
    sha.empty? ? nil : sha
  end

  # The commits that LANDED ON THE BASE, oldest first, so `(commits - late).last` is the
  # newest one the run could have seen. %cI is the COMMITTER date — the field the
  # incident was measured with.
  #
  # ── --first-parent IS LOAD-BEARING, NOT TIDINESS ────────────────────────────────
  #
  # A commit's committer date is when it was WRITTEN, not when it JOINED the base, and
  # those are different instants for every merge. `accepted` advances by merge commits
  # ("Merge pull request #NNNN") whose side-branch work is invariably OLDER than the
  # merge that lands it. Walking ALL commits in the range therefore classifies that
  # older work as "the run could have seen it" — when the run could not, because it was
  # not on `accepted` yet.
  #
  # THAT IS A FALSE PASS, AND IT LANDS ON EXACTLY THE MEASURED INCIDENT. Reproduced
  # against this module before the fix: side-branch work at 07:30:00Z, merged to
  # `accepted` at 07:59:02Z, CI completed 07:55:44Z. The whole-range walk marked the
  # 07:30 commit "covered", made it the covered_tip, and computed late_files as
  # diff(07:30-commit .. merge) — EMPTY, because the guard change came FROM that very
  # commit. Verdict: no guards, no refusal. The gate missed the case it exists for, and
  # PR #1258 was itself a merge commit, so this is the ordinary shape and not a corner.
  #
  # The first-parent chain is the order things landed on the base, which is the only
  # order the "could the run have seen it?" question is about. The side-branch commits
  # are not lost — they arrive through late_files, which is a two-point DIFF across the
  # merge and therefore carries everything the merge brought with it.
  def commits_between(root, from, to)
    out = IO.popen(["git", "-C", root.to_s, "log", "--reverse", "--first-parent",
                    "--format=%H%x00%cI%x00%s", "#{from}..#{to}"], err: File::NULL, &:read)
    return nil unless $?.success?

    out.to_s.lines.filter_map do |line|
      sha, at, subject = line.chomp.split("\0", 3)
      next if sha.to_s.empty?

      { sha: sha, at: at.to_s, subject: subject.to_s, time: parse_time(at) }
    end
  end

  def diff_files(root, from, to)
    out = IO.popen(["git", "-C", root.to_s, "diff", "--name-only", "#{from}..#{to}"],
                   err: File::NULL, &:read)
    return [] unless $?.success?

    out.to_s.lines.map(&:chomp).reject(&:empty?).uniq.sort
  end

  # An unparseable stamp is nil — "no clock", never "epoch", which would make every
  # commit look late and manufacture a refusal out of a read that failed.
  def parse_time(value)
    text = value.to_s.strip
    return nil if text.empty?

    Time.iso8601(text)
  rescue ArgumentError
    begin
      Time.parse(text)
    rescue ArgumentError
      nil
    end
  end
end
