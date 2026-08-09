# frozen_string_literal: true

require "json"
require_relative "projects_root"

# CertRootGuard — is this resolved CODE root the task's tree, and if not, what now?
#
# The G1 gates root at the cwd's git toplevel (RepoRoot.code_root), so a run from
# the WRONG checkout — e.g. the hub primary on main — roots at whatever tree it
# stands in. Because a cert's fingerprint is a git TREE hash, a foreign root is
# never harmlessly wrong; it is wrong in a direction, and the direction depends on
# whether the caller WRITES evidence or READS it. So the guard answers one question
# — "is `root` the task's tree?" — and the caller picks the remedy.
#
# A root is accepted as the task's tree when EITHER:
#   - its checked-out branch is the task's branch (board metadata.devops.branch,
#     falling back to the feat/<slug> convention — the same resolution
#     bin/task stale uses), OR
#   - it is the task's worktree directory (…/.worktrees/<worktree_slug>), which
#     covers detached-HEAD states (mid-rebase) inside the right worktree.
#
# THE TWO REMEDIES
#
#   * A cert WRITER — bin/fast-check, bin/full-suite-check — REFUSES (#refusal).
#     It STAMPS "[…@<fp>]" evidence about the tree it stands in, so from the wrong
#     checkout it green-certified code the task never touched: a fail-GREEN, hit
#     live 2026-07-12, caught only downstream by bin/dor-check's staleness. And it
#     must not silently chdir into the task worktree instead — that could green-cert
#     a STALE worktree while the operator's real edits sat untested in the checkout
#     they ran from, trading one fail-GREEN for another. Fail closed, say where to
#     run.
#
#   * The READER — bin/dor-check — RE-ROOTS (#assess → :resolved_root). It writes
#     no evidence, so re-rooting cannot forge a cert; it can only make the gate
#     grade the RIGHT tree instead of a foreign one. Refusing to read is the
#     costlier failure: because the fingerprint is content-addressed, a cert taken
#     in the task's worktree can NEVER match a primary checkout's tree, so
#     dor-check from the primary reported "STALE (certified for older code)" for
#     certs that were perfectly fresh — 6 of 6 tasks on 2026-07-14, including ones
#     certified green 90 seconds earlier. An agent that hits an unexplainable STALE
#     stops working, so the false STALE stranded finished tasks in `building`.
#     The re-root is LOUD by contract: the hazard of resolving is doing it
#     SILENTLY, which leaves the tool and the operator believing different things
#     about which code was judged.
#
#     The reader roots its DIFF here too, not just its fingerprint — and that half
#     fails in the opposite, worse direction. A foreign fingerprint can only read
#     STALE (a false REFUSAL, loud). A foreign DIFF reads as a real diff: run the
#     review gate-zero from a primary checkout carrying one unrelated dirty .md and
#     the gate observes a doc-only change, grants the `kind: chore` exemption, and
#     waves through a multi-file code PR. Same wrong tree, but a false PASS in the
#     gate whose whole job is refusing under-tested work (observed 2026-08-08,
#     task dor-check-review-rooting).
#
# The guard applies only to the IMPLICIT root (cwd-resolved). An EXPLICIT override
# (FULL_SUITE_ROOT / FAST_CHECK_ROOT / DOR_CHECK_DIFF_ROOT) bypasses it at the call
# site: the caller declared that root deliberately (the CI/test seam).
#
# Board reads are best-effort: an unreachable board falls back to the naming
# conventions, so the hub-primary-on-main case still refuses offline. A caller that
# already holds the task passes `devops:` and skips the board read entirely.
module CertRootGuard
  module_function

  # nil when `root` is `slug`'s tree (the cert may proceed); else the refusal
  # message. A blank slug (standalone --print / hook runs) never refuses —
  # there is no task to root at. The cert WRITERS' entry point.
  def refusal(task_bin:, slug:, root:, devops: nil, projects_dir: nil, prefer_repo: nil)
    found = assess(task_bin: task_bin, slug: slug, root: root, devops: devops,
                   projects_dir: projects_dir, prefer_repo: prefer_repo)
    return nil if found.nil?
    # The WRITER's half of the desk vouch (see #assess): standing physically at the
    # task's desk in the right repo still certifies, detached HEAD and all. The READER
    # deliberately does not honor this — same fact, opposite correct answer.
    return nil if found[:standing_in_task_desk]

    found[:message]
  end

  # The full assessment of `root` against the task. nil when `root` IS the task's
  # tree — the caller proceeds, unchanged. Otherwise a Hash the caller chooses a
  # remedy from (see THE TWO REMEDIES above):
  #
  #   :message         — the refusal text (what #refusal returns).
  #   :resolved_root   — the task's tree ON DISK, VALIDATED on both axes
  #                      (#worktree_mismatch), and unambiguous: nil unless exactly
  #                      one candidate qualifies. The RESOLVE half — a READER
  #                      re-roots at this instead of refusing. It is a FACT about the
  #                      destination, never a guess from its directory name.
  #   :candidate_roots — EVERY directory-name match on disk, qualified or not. What
  #                      the refusal enumerates.
  #   :eligible_roots  — the subset that passed both axes. More than one means a
  #                      MULTI-REPO task nothing could disambiguate; the caller
  #                      refuses rather than picking.
  #   :rejected_roots  — [[path, why], …] for the candidates that failed, so a
  #                      refusal can name which axis broke instead of just saying no.
  #   :expected_branch — the branch that IS the task's tree (board, else feat/<slug>).
  #   :actual_branch   — what `root` has checked out ("HEAD" when detached, nil when
  #                      `root` isn't a git tree at all).
  #   :worktree_slug   — the task's worktree slug.
  #
  # `devops` short-circuits the board read for a caller that already holds the task;
  # `projects_dir` overrides where the worktree glob looks (the test seam);
  # `prefer_repo` breaks a multi-repo tie (see #worktree_hint).
  def assess(task_bin:, slug:, root:, devops: nil, projects_dir: nil, prefer_repo: nil)
    return nil if slug.to_s.strip.empty?

    devops ||= task_devops(task_bin, slug)
    expected_branch = first_present(devops["branch"], "feat/#{slug}")
    worktree_slug = first_present(devops["worktree_slug"], slug)
    actual_branch = current_branch(root)

    # SYMMETRY. The root you are STANDING in faces exactly the two axes any candidate
    # destination faces. It did not used to: this line was branch-only (the repo axis
    # was never asked of it) and was backed by a `worktree_dir?` STRING match, so a
    # stale desk on `release`, a detached HEAD in the right desk, and — live on disk
    # today — standing in studio-engine's `repair-moms-app-ci` desk while the PR is
    # moms-app's, all short-circuited to "you are the task's tree" and were graded
    # with no validation and no banner. Validating the destination while trusting the
    # source, inside one guard, is the same defect this guard exists to close, just
    # pointing the other way (review round 4).
    standing_mismatch = worktree_mismatch(root, expected_branch: expected_branch, prefer_repo: prefer_repo)
    return nil if standing_mismatch.nil?

    # The PHYSICAL desk vouch — …/.worktrees/<worktree_slug>, in the right repo. It
    # survives the branch axis but NOT the repo axis, and it is now a REPORTED FACT
    # rather than a short-circuit, because the two consumers want opposite answers
    # (the REFUSE-vs-RESOLVE split at the top of this file):
    #
    #   a WRITER (bin/fast-check, bin/full-suite-check) accepts it — the operator is
    #     physically working at the task's desk, and a cert stamped mid-rebase is
    #     content-addressed, so it can only later read STALE: loud and self-correcting.
    #   the READER (bin/dor-check) must NOT: a detached HEAD is not the PR's state, and
    #     a diff read from it is graded as though it were. That direction fails SILENT
    #     and passing, which is the whole subject of this task.
    #
    # #refusal honors it; dor-check ignores it deliberately.
    #
    # Branch-forgiving and deliberately REPO-BLIND. The first cut also required the
    # repo axis here, which mutation-testing exposed as dead code: only #refusal reads
    # this, and the cert writers pass no `prefer_repo`. The fix is NOT to feed them one
    # — `devops.pr_url` is a SINGLE value (the known gap in gates/dor.md), so on a
    # multi-repo task it names one repo while the builder may legitimately be
    # certifying in another. Enforcing it here would refuse honest work, which is the
    # one thing a cert writer must not do casually. The wrong-repo desk is closed for
    # the READER by `standing_mismatch` above, where failing closed is safe.
    standing_in_task_desk = worktree_dir?(root, worktree_slug)

    candidates = worktree_candidates(worktree_slug, projects_dir)
    rejected = candidates.filter_map do |path|
      why = worktree_mismatch(path, expected_branch: expected_branch, prefer_repo: prefer_repo)
      [path, why] if why
    end
    eligible = candidates - rejected.map(&:first)
    resolved = (eligible.first if eligible.size == 1)

    {
      message: refusal_message(slug, root, actual_branch, expected_branch, worktree_slug, projects_dir,
                               resolved: resolved, prefer_repo: prefer_repo),
      # Why the STANDING root is not the task's tree ("is on branch release, not
      # feat/x" / "answers to repo …"), so a caller can say which axis failed without
      # re-deriving it.
      standing_mismatch: standing_mismatch,
      standing_in_task_desk: standing_in_task_desk,
      # Exactly one VALIDATED tree, or nothing. Not "the best of the candidates" —
      # a destination nobody checked is how B1/B2 turned a re-root into a false pass.
      resolved_root: resolved,
      candidate_roots: candidates,
      eligible_roots: eligible,
      rejected_roots: rejected,
      expected_branch: expected_branch,
      actual_branch: actual_branch,
      worktree_slug: worktree_slug
    }
  end

  # The cert writers' refusal text: where you ARE, where the task's tree IS, and the
  # concrete `cd` that fixes it when the worktree is on disk.
  #
  # `resolved` is the VALIDATED destination when the caller already computed one. It
  # matters because the `cd` line is advice someone will follow: pointing it at a
  # directory that merely carries the task's NAME — a stale desk on `release`, or
  # another repo's worktree — sends the reader to certify the wrong tree. Without a
  # validated tree the advice stays generic rather than confidently wrong.
  def refusal_message(slug, root, actual_branch, expected_branch, worktree_slug, projects_dir = nil,
                      resolved: nil, prefer_repo: nil)
    message = "this run roots at #{root} (branch #{actual_branch || 'unknown'}), " \
              "which is not #{slug}'s tree — refusing to certify it.\n" \
              "Expected branch #{expected_branch} or the task worktree .worktrees/#{worktree_slug}."
    # `prefer_repo` threads through because this `cd` line is advice someone FOLLOWS,
    # and it is the text bin/ship, bin/fast-check and bin/full-suite-check all die!
    # with — so dropping the repo filter here sent four callers to a validated-but-
    # wrong-repo desk while the comment above claimed the tie was broken.
    hint = resolved || eligible_worktrees(worktree_slug, expected_branch, projects_dir: projects_dir,
                                          prefer_repo: prefer_repo).first
    message += "\nRun the cert from the task worktree: cd #{hint}" if hint
    message
  end

  # The branch checked out at `dir`, or nil. Errors and empty output read as
  # nil; a detached HEAD reads as "HEAD", which never matches a task branch.
  def current_branch(dir)
    out = IO.popen(["git", "-C", dir.to_s, "rev-parse", "--abbrev-ref", "HEAD"],
                   err: File::NULL, &:read).to_s.strip
    out.empty? ? nil : out
  rescue StandardError
    nil
  end

  # The task's devops metadata via `<task_bin> show <slug> --json`; {} on any
  # failure so the caller falls back to the naming conventions.
  def task_devops(task_bin, slug)
    out = IO.popen([task_bin, "show", slug, "--json"], err: File::NULL, &:read)
    return {} unless $?.success?

    JSON.parse(out).dig("metadata", "devops") || {}
  rescue StandardError
    {}
  end

  # True when `dir` IS a `.worktrees/<worktree_slug>` checkout.
  def worktree_dir?(dir, worktree_slug)
    File.basename(dir.to_s) == worktree_slug &&
      File.basename(File.dirname(dir.to_s)) == ".worktrees"
  end

  # EVERY …/<app>/.worktrees/<worktree_slug> on disk under the projects root, sorted.
  # The glob spans every app because a SATELLITE task (turf-monster, rolio) runs the
  # hub's gate scripts — its worktree lives under the satellite, not the hub.
  #
  # It returns the whole SET, not the first hit, because a MULTI-REPO task
  # legitimately has one worktree per repo under the SAME slug — live on this machine
  # today, e.g. `repair-moms-app-ci` exists under both moms-app and studio-engine. The
  # glob is alphabetical, so a first-hit pick silently answers "which repo is this
  # task's tree?" with "whichever sorts first", which is how a gate ends up grading
  # moms-app's tree for a studio-engine PR. `projects_dir` overrides the search root
  # (the test seam). Best-effort: [] on any failure.
  def worktree_candidates(worktree_slug, projects_dir = nil)
    base = projects_dir.to_s.strip.empty? ? ProjectsRoot.default_projects_dir : projects_dir.to_s
    Dir.glob(File.join(base, "*", ".worktrees", worktree_slug)).select { |path| File.directory?(path) }.sort
  rescue StandardError
    []
  end

  # The app a worktree belongs to: …/<app>/.worktrees/<slug> → "<app>".
  def app_of(worktree_path)
    File.basename(File.expand_path("../..", worktree_path.to_s))
  end

  # WHY `path` is not the task's tree — or nil when it IS. The DESTINATION check,
  # and the reason it exists: #assess interrogates the root you are STANDING in on
  # two axes, and the first cut of the re-root asked the root it JUMPED TO nothing
  # at all. A candidate qualified by having the right DIRECTORY NAME, while the
  # caller announced "Re-rooted at the task's worktree" as established fact. Two
  # independent false passes came straight back through that door (review of
  # 2026-08-09): a worktree with the right branch in the WRONG REPO, and a stale desk
  # in the right repo that never carried the branch. Either axis alone would have
  # missed one of them, so BOTH are asked here, and the answer names which failed.
  #
  #   repo   — checked only when `prefer_repo` is known (devops.pr_url names it). A
  #            builder's pre-PR run has no repo to compare against; demanding one
  #            would refuse every legitimate pre-PR re-root. Each axis is enforced
  #            whenever it is determinable.
  #   branch — always. A tree that is not on the task's branch cannot be the tree the
  #            builder certified, whatever it is called on disk. A detached HEAD reads
  #            as "HEAD" and is refused too: fail closed on the destination, and let
  #            the caller declare an explicit root if they really mean it.
  def worktree_mismatch(path, expected_branch:, prefer_repo: nil)
    repo_mismatch(path, prefer_repo) || branch_mismatch(path, expected_branch)
  end

  # The REPO axis, alone — split out because the physical-desk vouch below needs it
  # WITHOUT the branch axis. nil when the checkout answers to `prefer_repo`, or when
  # there is no preference to check against.
  #
  # OWNER-AWARE when it can be. `origin` is authoritative — it IS the GitHub repo this
  # checkout pushes to — and it carries the owner, so a FORK (same repo name, someone
  # else's account) is a positive contradiction rather than a match. Only when there is
  # no origin at all does this fall back to the app DIRECTORY name, which cannot know
  # an owner; a bare-name comparison is weaker, but it is the convention the worktree
  # glob is built on and it beats having no answer.
  #
  # Falling back matters in the other direction too: directory name ALONE would refuse a
  # perfectly good worktree whenever a repo's GitHub name differs from the folder someone
  # cloned it into — a naming mismatch nobody chose, turning a working review into a dead
  # end. So the axis rejects only on a positive contradiction, never on absent information.
  def repo_mismatch(path, prefer_repo)
    wanted = prefer_repo.to_s.strip
    return nil if wanted.empty?

    remote = remote_slug(path)
    if remote
      return nil if slugs_match?(remote, wanted)

      return "answers to repo #{remote}, not #{wanted}"
    end

    dir = app_of(path)
    return nil if dir.casecmp?(wanted.split("/").last.to_s)

    "answers to repo #{dir}, not #{wanted.split('/').last}"
  end

  # The BRANCH axis, alone. A detached HEAD reads as "HEAD" and never matches.
  def branch_mismatch(path, expected_branch)
    actual = current_branch(path)
    return nil if actual == expected_branch

    "is on branch #{actual || 'unknown'}, not #{expected_branch}"
  end

  # "Owner/repo" from `origin`, or nil when there is no origin (normal in a freshly
  # `git init`ed tree and in test fixtures).
  def remote_slug(dir)
    url = IO.popen(["git", "-C", dir.to_s, "remote", "get-url", "origin"], err: File::NULL, &:read)
    remote_slug_from(url)
  rescue StandardError
    nil
  end

  # The parsing half, kept pure so it is testable without a git fixture:
  # "git@github.com:Owner/turf-monster.git" and
  # "https://github.com/Owner/turf-monster" both → "Owner/turf-monster".
  def remote_slug_from(url)
    text = url.to_s.strip
    return nil if text.empty?

    text[%r{[:/]([^/:]+/[^/:]+?)(?:\.git)?/?\z}, 1]
  end

  # Two repo references name the same repo. Compared case-insensitively (GitHub is),
  # and owner-to-owner ONLY when both sides carry an owner — a bare "turf-monster"
  # from a directory name cannot vouch for an owner, and pretending it can would
  # either refuse everything or wave forks through depending on which way we guessed.
  def slugs_match?(a, b)
    left = a.to_s.split("/")
    right = b.to_s.split("/")
    return left.last.to_s.casecmp?(right.last.to_s) if left.size < 2 || right.size < 2

    left.last(2).join("/").casecmp?(right.last(2).join("/"))
  end

  # The candidates that survive #worktree_mismatch — the trees that really are this
  # task's, as opposed to the ones merely NAMED after it.
  def eligible_worktrees(worktree_slug, expected_branch, projects_dir: nil, prefer_repo: nil)
    worktree_candidates(worktree_slug, projects_dir).reject do |path|
      worktree_mismatch(path, expected_branch: expected_branch, prefer_repo: prefer_repo)
    end
  end

  # The task's tree ON DISK. Doubles as the refusal's `cd` hint and the reader's
  # :resolved_root. `prefer_repo` — the app the work under gate belongs to, e.g. the
  # repo named by the task's PR URL — breaks a multi-repo tie; with no preference (or
  # no match) this falls back to the first candidate, and the caller decides from
  # :candidate_roots whether that guess is safe to act on. nil when nothing matches.
  def worktree_hint(worktree_slug, projects_dir = nil, prefer_repo: nil)
    candidates = worktree_candidates(worktree_slug, projects_dir)
    wanted = prefer_repo.to_s.strip
    preferred = wanted.empty? ? nil : candidates.find { |path| app_of(path) == wanted }
    preferred || candidates.first
  end

  # The first argument whose string form isn't blank (nil when all are).
  def first_present(*values)
    values.find { |v| !v.to_s.strip.empty? }
  end
end
