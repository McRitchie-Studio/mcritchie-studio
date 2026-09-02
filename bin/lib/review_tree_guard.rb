# frozen_string_literal: true

# IS THE TREE THIS REVIEW GRADES THE TREE THAT WILL MERGE?
#
# Two questions with one subject, both raised by /tasks/reviewer-zap-has-unmapped-seams
# after three reviewer zaps on 2026-09-02 turned up three unguarded seams. A ZAP is a
# reviewer fixing a small defect forward on the PR branch instead of spending a bounce
# — an ENCOURAGED act (the zap protocol bounds it at 25 lines / 2 files). The machinery
# around it, however, assumed nobody pushed.
#
# WHY THIS IS A GUARD RATHER THAN A DISCIPLINE. Every seam below makes zapping quietly
# RISKIER than bouncing, which is exactly the wrong incentive: it pushes reviewers
# toward the expensive action. Two reviewers that day got the right answer only because
# they happened to re-verify by hand. Nothing forced them to, and nothing would have
# told them if they hadn't.
#
# ── SEAM 1: THE GATE READS THE PRE-ZAP TREE ────────────────────────────────────
#
# `bin/dor-check --gate-role review` re-roots to the BUILDER'S DESK (bin/lib/
# cert_root_guard.rb picks the worktree on the task's branch). That desk sits wherever
# the builder left it. Measured on turf #519: the desk was at 262059b, one commit
# behind the merged 9137d57. So the verdict's CI half came from the PR head while its
# tree half came from a commit that is not the one merging.
#
# THE FINGERPRINT HALF ALREADY BITES — BUT ONLY SOMETIMES, AND THE CONDITION IS THE
# WHOLE POINT. The cert is bound to a git TREE hash, so a zap changes the tree and the
# cert reads STALE (observed on solana-studio #29: the reviewer's zaps invalidated the
# cert and dor-check correctly refused until he re-certified). That works ONLY when the
# ref it hashes has actually seen the zap. `review_fingerprint` hashes `origin/<branch>`
# (else the local `<branch>`) IN THE DESK, and **bin/dor-check never runs `git fetch`**
# — verified 2026-09-02: every `fetch` in that script is prose in a remedy string. A
# reviewer who zaps from the desk itself updates that ref as a side effect of pushing,
# and the cert goes stale exactly as observed. A reviewer who zaps from ANYWHERE ELSE
# leaves the desk's ref pre-zap, the hash matches the cert the builder stamped, and the
# lane reads FRESH. Same act, opposite outcome, decided by which checkout the reviewer
# happened to be standing in.
#
# So this asks the question the fingerprint cannot: does the commit this gate is about
# to grade EQUAL the PR head? A mismatch is refused rather than reconciled, because the
# gate has no business inventing a tree it cannot see.
#
# DIRECTION OF ERROR, stated plainly: a mismatch can only ever produce a FALSE REFUSAL
# (an unfetched desk), never a false pass. The remedy for that refusal — fetch the
# branch — is also the remedy for the real defect, so the cheap failure and the correct
# fix are the same action. That asymmetry is why this fails closed.
#
# ── SEAM 2: `accepted` MOVES MID-REVIEW AND THE DECLARED-SET CHECK GOES STALE ──
#
# Measured: turf #517 merged at 14:28:30Z while #519's CI ran 14:26:34–14:32:39Z, so
# #519's e2e declared-set check finished 97 SECONDS BEFORE that merge landed — and #517
# touched BOTH e2e/auth_modal.spec.js and config/e2e_lane.yml, the spec set and the
# contract that counts it. The reviewer re-derived by hand and it happened to be
# spec-count-neutral. It might not have been.
#
# GitHub already answers a version of this, and it is not enough. bin/dor-check refuses
# a green CI when `mergeStateStatus` is BEHIND (CiStatus.base_drift). But GitHub reports
# BEHIND only where branch protection demands an up-to-date branch; the ordinary case is
# CLEAN, and `""`/UNKNOWN maps to :unknown, which that gate passes over in silence. So
# the one signal in hand can say nothing precisely when nothing is configured to make it
# speak.
#
# This re-derives the same fact from refs instead of asking GitHub's opinion: is the
# base branch's tip an ANCESTOR of the PR branch? If not, the base moved after the
# branch last took it, and every check that ran against the old merge — the e2e
# declared/executed-set arithmetic included — describes a tree the merge will not
# produce.
#
# THE ASYMMETRY THAT MAKES THIS HONEST, and it is the opposite of seam 1's. These are
# LOCAL refs and this gate never fetches, so `origin/<base>` may itself be behind the
# real base. Therefore:
#   :moved            is TRUSTWORTHY — a tip that is not an ancestor really is not one,
#                     and a staler ref could only UNDERSTATE the movement.
#   :no_movement_seen is NOT PROOF OF FRESHNESS — it is "the refs I can see show none",
#                     which is a different sentence and must never be printed as the
#                     first one.
# Collapsing those two is the mistake this whole task is about, one level down: a gate
# that reports what it could not check as though it had checked it.
#
# ── SEAM 3: DELIBERATELY ABSENT ───────────────────────────────────────────────
#
# A third seam was filed: a reviewer zap was believed to demote a task out of the review
# queue (`submitted` → `building`), citing turf #513. THAT WAS FALSIFIED — on #518 a
# reviewer pushed a zap and the task STAYED `submitted` with the breaker clear. What
# actually moved #513 overnight is STILL UNIDENTIFIED, and no zap-demotion mechanism is
# encoded here, in the tests, or in the comments. See the module's task record for the
# enumerated stage-writers found while looking. An honest gap beats a tidy wrong story.
module ReviewTreeGuard
  # The first of `refs` that resolves here, as { sha:, ref: } — or nil when none does.
  # Mirrors FullSuiteGate.fingerprint_of_first_ref's shape (hash WITH its provenance)
  # for the same reason: a SHA whose origin the verdict cannot name is a number nobody
  # can re-derive, and this gate exists to be re-derivable by hand.
  def self.commit_of_first_ref(root, *refs)
    refs.flatten.compact.map(&:to_s).reject(&:empty?).each do |ref|
      out = IO.popen(["git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}"],
                     err: File::NULL, &:read)
      next unless $?.success?

      sha = out.to_s.strip
      return { sha: sha, ref: ref } unless sha.empty?
    end
    nil
  rescue SystemCallError, IOError
    nil
  end

  # SEAM 1. Does the commit this gate is about to grade equal the PR head?
  #
  # `pr_head` is the PR's headRefOid (CiStatus carries it on the verdict). Returns a
  # hash whose :state is one of:
  #   :match        — the graded ref IS the PR head. The verdict describes the merge.
  #   :mismatch     — it is NOT. Somebody pushed (a reviewer zap is the common cause)
  #                   and this checkout has not seen it.
  #   :unobservable — no PR head to compare against, or no local ref for the branch.
  #                   NOT a pass and NOT a failure: the question could not be asked,
  #                   and the caller decides what that is worth in its role.
  #
  # Refs are tried in the SAME ORDER review_fingerprint hashes them (`origin/<branch>`,
  # then the local `<branch>`) — deliberately, so this answers about the very commit the
  # cert was graded against rather than about some neighbouring ref. If those two ever
  # diverge, this guard stops describing the tree the verdict used, which is the one
  # thing it must never do.
  def self.head_assessment(root:, branch:, pr_head:)
    head = pr_head.to_s.strip
    local = branch.to_s.strip.empty? ? nil : commit_of_first_ref(root, "origin/#{branch}", branch.to_s)

    return { state: :unobservable, reason: :no_pr_head, local: local, branch: branch.to_s } if head.empty?
    return { state: :unobservable, reason: :no_local_ref, pr_head: head, branch: branch.to_s } if local.nil?

    state = same_commit?(local[:sha], head) ? :match : :mismatch
    { state: state, pr_head: head, local_sha: local[:sha], ref: local[:ref], branch: branch.to_s }
  end

  # SEAM 2. Has the base moved out from under this branch, re-derived from refs?
  #
  #   :moved            — the base tip is NOT an ancestor of the branch. TRUSTWORTHY
  #                       (see the module header): a staler ref could only understate.
  #                       :behind_by counts the base commits the branch has not taken.
  #   :no_movement_seen — the base tip IS an ancestor OF THE REFS THIS CHECKOUT HAS.
  #                       Not a freshness certificate; this gate never fetches.
  #   :unobservable     — a ref is missing, so the question could not be asked.
  def self.base_assessment(root:, branch:, base:)
    base_ref = base.to_s.strip
    return { state: :unobservable, reason: :no_base } if base_ref.empty?

    base_commit = commit_of_first_ref(root, "origin/#{base_ref}", base_ref)
    branch_commit = branch.to_s.strip.empty? ? nil : commit_of_first_ref(root, "origin/#{branch}", branch.to_s)
    return { state: :unobservable, reason: :no_base_ref, base: base_ref } if base_commit.nil?
    return { state: :unobservable, reason: :no_branch_ref, base: base_ref } if branch_commit.nil?

    ancestor = system("git", "-C", root.to_s, "merge-base", "--is-ancestor",
                      base_commit[:sha], branch_commit[:sha],
                      out: File::NULL, err: File::NULL)
    common = { base: base_ref, base_ref: base_commit[:ref], base_sha: base_commit[:sha],
               branch_ref: branch_commit[:ref], branch_sha: branch_commit[:sha] }
    return common.merge(state: :no_movement_seen) if ancestor

    common.merge(state: :moved, behind_by: count_commits(root, branch_commit[:sha], base_commit[:sha]))
  rescue SystemCallError, IOError
    { state: :unobservable, reason: :git_unreadable, base: base.to_s }
  end

  # How many commits the base has that the branch does not. Reported, never gating —
  # a count that fails to compute must not turn a real :moved into silence, so this
  # degrades to nil and the caller's message drops the number rather than the finding.
  def self.count_commits(root, from_sha, to_sha)
    out = IO.popen(["git", "-C", root.to_s, "rev-list", "--count", "#{from_sha}..#{to_sha}"],
                   err: File::NULL, &:read)
    return nil unless $?.success?

    value = out.to_s.strip
    value.match?(/\A\d+\z/) ? value.to_i : nil
  rescue SystemCallError, IOError
    nil
  end

  # ABBREVIATION-TOLERANT, in one direction only. `gh` and git hand back SHAs at
  # different widths, and a 40-char local SHA must still match a 7-char head. Compared
  # by prefix on the SHORTER string — but only when that string is long enough to mean
  # something: git's own floor is 4, and anything below it would make unrelated commits
  # "match", which on this guard is a false PASS. Below the floor, refuse to call it a
  # match; the caller's fail-closed path is the correct answer to "I cannot tell".
  MIN_ABBREV = 4

  def self.same_commit?(one, two)
    a = one.to_s.strip.downcase
    b = two.to_s.strip.downcase
    return false if a.empty? || b.empty?

    width = [a.length, b.length].min
    return false if width < MIN_ABBREV

    a[0, width] == b[0, width]
  end
end
