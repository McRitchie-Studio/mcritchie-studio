# frozen_string_literal: true

# Regression for the bin/dor-check DIFF rooting — the FALSE PASS half of the
# wrong-tree family.
#   ruby -Itest test/lib/dor_check_review_diff_rooting_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE BUG (2026-08-08, task dor-check-review-rooting). `bin/dor-check <task>
# --gate-role review`, run from the mcritchie-studio PRIMARY checkout — which is
# EXACTLY what pr-review-primary.md instructs (its Entry says `cd
# /Users/alex/projects/mcritchie-studio`, a later step says run the gate, and nothing
# pins either to the task's tree) — inspected the PRIMARY's working tree instead of
# the task's diff. Observed, verbatim, over a multi-file code PR:
#
#   ✓ DoR-to-Merge n/a … doc-only diff (kind: chore): 1 file(s), none behavioral —
#     docs/agents/maintenance/delete-later.md [source: git working tree]
#     → ready to advance submitted → reviewed
#
# That file was one unrelated dirty file on the primary's `main`. The PR was a
# multi-file code change. Re-run rooted at the task's worktree, the same command
# evaluated the real diff and passed honestly.
#
# WHY THIS IS THE DANGEROUS DIRECTION. The 2026-07-14 fix
# (test/lib/dor_check_root_guard_test.rb) rooted the cert FINGERPRINT and stopped at
# the builder lane, reasoning that review "already roots at the branch tree". True of
# the fingerprint; false of the DIFF, which never re-rooted in either lane. And the
# two fail OPPOSITELY: a foreign fingerprint can only ever produce a false STALE —
# loud, self-correcting, nobody accepts an unexplained refusal. A foreign DIFF
# produces a false PASS in the gate whose entire job is refusing under-tested work,
# it is indistinguishable from a real verdict, and the dirtier the checkout the more
# confidently it lies.
#
# THE INVARIANT THESE TESTS ASSERT, in both directions:
#
#     dor-check's diff is the TASK's diff. Never the diff of the tree you stand in —
#     which can wave code through (a dirty .md here) just as easily as it can block
#     prose (a dirty .rb here).
#
# A happy-path test would have passed BEFORE this fix and proves nothing, so every
# integration case below stands in a checkout that is deliberately dirty with files
# that would flip the verdict if they were read.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/cert_root_guard.rb", __dir__)

class DorCheckReviewDiffRootingTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "task-x"
  # The exact file from the observed false pass. Prose, so reading it from the wrong
  # tree buys the `kind: chore` exemption.
  PRIMARY_DIRT = "docs/agents/maintenance/delete-later.md"
  # The PR's real contents: MULTI-FILE and behavioral, so a gate that sees them
  # cannot possibly call the change doc-only.
  PR_CODE = ["app/services/widget.rb", "app/models/gadget.rb"].freeze

  # ── git fixtures ───────────────────────────────────────────────────────────

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # A repo that ignores /.worktrees/, exactly as every managed repo does (see this
  # repo's own .gitignore: "Hidden per-task git worktrees created by
  # bin/agent-worktree"). This is not decoration — WITHOUT it the primary's untracked
  # listing includes `.worktrees/<slug>/`, which classifies as behavioral, and the
  # pre-fix run gets GATED by the very worktree it was failing to look inside. The
  # fixture would then redden on the wrong-tree assertion while never reproducing the
  # false PASS the whole task is about.
  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    real = File.realpath(dir)
    git!(real, "init", "-q")
    git!(real, "config", "user.email", "t@t.co")
    git!(real, "config", "user.name", "T")
    write(real, "README.md", "base\n")
    write(real, ".gitignore", "/.worktrees/\n")
    git!(real, "add", "-A")
    git!(real, "commit", "-qm", "init")
    real
  end

  # A task tree: the base rung recorded as a remote ref, then the feature committed
  # on feat/<slug> — the state a REVIEWER meets (branch pushed, nothing uncommitted).
  #
  # `base_rung` is the rung this repo actually has. Post-v2 hub/satellite repos have
  # origin/accepted; a moms-app-style repo has only origin/main, and the gate must
  # resolve each repo's OWN base rather than assuming one ladder.
  def build_task_tree(dir, files:, base_rung: "accepted", branch: "feat/#{SLUG}")
    tree = init_repo(dir)
    git!(tree, "update-ref", "refs/remotes/origin/#{base_rung}", "HEAD")
    git!(tree, "checkout", "-q", "-b", branch)
    files.each { |rel| write(tree, rel, "# #{rel}\n") }
    git!(tree, "add", "-A")
    git!(tree, "commit", "-qm", "feat")
    git!(tree, "update-ref", "refs/remotes/origin/#{branch}", branch)
    tree
  end

  # The world the bug lives in:
  #
  #   <projects>/myapp/                    ← the PRIMARY the reviewer stands in, on
  #                                          `release`, DIRTY with `dirt` — files that
  #                                          are not the task's and never were.
  #   <projects>/myapp/.worktrees/task-x/  ← the task's tree, carrying `files` on
  #                                          feat/task-x.
  #
  # `worktree: false` omits the task tree entirely. Yields [projects, primary, tree].
  def with_world(files: PR_CODE, dirt: [PRIMARY_DIRT], worktree: true, base_rung: "accepted")
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"))
      git!(primary, "checkout", "-q", "-b", "release")
      dirt.each { |rel| write(primary, rel, "unrelated local scratch\n") }

      tree = nil
      tree = build_task_tree(File.join(projects, "myapp", ".worktrees", SLUG), files: files,
                             base_rung: base_rung) if worktree
      yield projects, primary, tree
    end
  end

  # ── the task fixture ───────────────────────────────────────────────────────

  # A `kind: chore` task — an EXEMPT kind, so the whole shape/test-tier gate hangs on
  # one question: does the observed diff ship behavior? That makes it the exact shape
  # the false pass needs, and the sharpest probe of WHICH tree got observed.
  def chore_task(slug: SLUG, repo: "myapp", pr: true)
    {
      "slug" => slug, "title" => "Task X",
      "metadata" => { "devops" => {
        "kind" => "chore",
        "branch" => "feat/#{slug}",
        "worktree_slug" => slug,
        "pr_url" => (pr ? "https://github.com/McRitchie-Studio/#{repo}/pull/7" : nil),
        "acceptance" => ["read the task's diff"],
        "repositories" => [repo],
        "risk_tags" => ["gate-integrity"],
        "test_plan" => ["[unit] resolver", "[integration] dor-check"],
        "post_deploy_cmd" => "none",
        "checks_run" => []
      }.compact }
    }
  end

  # Run bin/dor-check FROM `cwd` with an IMPLICIT root (no DOR_CHECK_DIFF_ROOT — an
  # explicit one is the caller declaring a root, and bypasses the guard by design).
  #
  # DOR_CHECK_PR_FILES=unverified simulates the observed condition: `gh` could not
  # read the PR's file list, so the resolver falls back to a local view. That
  # fallback is the whole subject of this file — when it is allowed to be the
  # PRIMARY's working tree, the gate lies.
  #
  # Returns [verdict_hash, exit_code, stderr].
  def dor_check(task, cwd, projects, *args, pr_files: "unverified")
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      err = File.join(d, "stderr.txt")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil, # exercise the real release-aware base resolver
        "DOR_CHECK_PR_FILES" => pr_files,
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_PROJECTS_DIR" => projects
      )
      out = IO.popen(env, "#{BIN} #{task['slug']} --file #{path} --json #{args.join(' ')} 2>#{err}",
                     chdir: cwd, &:read)
      [JSON.parse(out), $?.exitstatus, File.read(err)]
    end
  end

  # The verdict describes SOME tree; these say which, positively.
  def assert_saw_the_prs_code(verdict, code, files: PR_CODE)
    # First, and most specifically: the false PASS itself. A `kind: chore` whose PR
    # ships behavior must never collect the doc-only exemption, whatever tree the
    # caller is standing in.
    refute verdict["exempt"], "THE BUG: the doc-only exemption granted to a multi-file code PR"
    assert_equal 1, code, "a multi-file code diff on an unshaped chore must NOT advance: #{verdict['errors']}"
    refute verdict["ready"]
    assert_equal files.sort, Array(verdict["changed_files"]).sort,
                 "the gate must have observed the TASK's files"
    refute_includes Array(verdict["changed_files"]), PRIMARY_DIRT,
                    "the standing checkout's unrelated dirt is not this task's diff"
    assert_match(/ships a code diff/, verdict["errors"].join(" "),
                 "seeing the code must trigger the shape/test-tier gate")
  end

  # ── [unit] the resolver: which tree belongs to this task ───────────────────

  def with_two_repo_worktrees
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      # Alphabetical order decides a first-hit pick, so name them so the WRONG one
      # sorts first. This is the live shape on the operator's machine today:
      # repair-moms-app-ci exists under BOTH moms-app and studio-engine.
      a = File.join(projects, "aaa-app", ".worktrees", SLUG)
      b = File.join(projects, "zzz-app", ".worktrees", SLUG)
      [a, b].each { |p| FileUtils.mkdir_p(p) }
      yield projects, a, b
    end
  end

  def test_unit_worktree_candidates_lists_every_repos_worktree
    with_two_repo_worktrees do |projects, a, b|
      assert_equal [a, b].sort, CertRootGuard.worktree_candidates(SLUG, projects),
                   "a multi-repo task has one worktree per repo; the set is the fact, the pick is a guess"
      assert_empty CertRootGuard.worktree_candidates("never-created", projects)
    end
  end

  def test_unit_worktree_hint_prefers_the_repo_the_work_belongs_to
    with_two_repo_worktrees do |projects, a, b|
      assert_equal b, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "zzz-app"),
                   "the preference must beat glob order, or the tie is decided alphabetically"
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "aaa-app")
    end
  end

  def test_unit_worktree_hint_without_a_preference_is_unchanged
    # The cert writers call this positionally for a `cd` hint and must keep their
    # existing behavior: first candidate, nil when there is none.
    with_two_repo_worktrees do |projects, a, _b|
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects)
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "no-such-app")
      assert_nil CertRootGuard.worktree_hint("never-created", projects)
    end
  end

  def test_unit_app_of_names_the_repo_a_worktree_belongs_to
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster/.worktrees/task-x")
  end

  # ── [integration] THE FALSE PASS ───────────────────────────────────────────

  def test_integration_a_dirty_primary_cannot_pass_a_code_pr_off_as_doc_only_in_review
    # THE MUTATION, reproduced exactly: review lane, run from the primary, PR files
    # unreadable, one unrelated dirty .md on the primary, a multi-file code PR in the
    # task's worktree. Pre-fix this printed "✓ DoR-to-Merge n/a … doc-only diff …
    # → ready to advance" and exited 0.
    with_world do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      # THE PAIRING is the invariant, not the source label: "git working tree" is a
      # perfectly good answer FROM the task's tree, and a lie from anywhere else. The
      # verdict now carries both halves so the pairing can be checked at all.
      assert_equal "git", verdict["diff_source"]
      assert_equal tree, verdict["code_root"],
                   "a working-tree read must be a read of the TASK's working tree"
      refute_equal primary, verdict["code_root"], "grading the checkout you STAND in is the bug itself"
    end
  end

  def test_integration_the_builder_lane_is_held_to_the_same_rule
    # Same world, the other role. The guard was builder-only before this fix and the
    # roles must not drift again: one lane rooted correctly is how the review hole
    # survived a month of green tests.
    with_world do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects)

      assert_saw_the_prs_code(verdict, code)
      assert_equal tree, verdict["code_root"]
    end
  end

  def test_integration_the_diff_re_root_is_announced_naming_both_trees
    # A gate that silently judges a different tree than the one you are looking at is
    # how you argue with a verdict instead of reading it (cert_root_guard.rb's own
    # contract). The banner must name where you ARE and where it WENT.
    with_world do |projects, primary, tree|
      _verdict, _code, stderr = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_includes stderr, primary, "name the root you were standing in"
      assert_includes stderr, tree, "name the root it moved to"
    end
  end

  # ── [integration] the OTHER direction: it must not over-refuse ─────────────

  def test_integration_a_genuinely_doc_only_pr_still_earns_its_exemption_from_the_primary
    # The mirror-image mutation. Here the PR really is prose and the PRIMARY is dirty
    # with CODE — so a gate reading the wrong tree fails the OTHER way, refusing an
    # honest chore. Re-rooting has to fix the tree, not the answer: the exemption must
    # still be granted, and granted on the TASK's files.
    with_world(files: ["docs/agents/modules/heartbeats.md"], dirt: ["app/services/rogue.rb"]) do |projects, primary, _tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_equal 0, code, "a doc-only PR must still pass: #{verdict['errors']}"
      assert verdict["ready"]
      assert verdict["exempt"]
      assert_equal ["docs/agents/modules/heartbeats.md"], verdict["changed_files"]
      refute_includes Array(verdict["changed_files"]), "app/services/rogue.rb",
                      "the primary's dirty code must not be blamed on this task either"
    end
  end

  def test_integration_a_readable_pr_file_list_still_wins
    # Source priority is unchanged: the PR is the artifact under gate, and reading it
    # is repo-correct from anywhere. The re-rooting is the FALLBACK's cure, not a
    # replacement for it.
    with_world do |projects, primary, _tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review",
                                 pr_files: "app/jobs/from_the_pr.rb")

      assert_equal "pr", verdict["diff_source"]
      assert_equal ["app/jobs/from_the_pr.rb"], verdict["changed_files"]
      assert_equal 1, code
    end
  end

  # ── [integration] no worktree on disk: the branch, else fail closed ────────

  def test_integration_reads_the_branch_diff_when_the_worktree_is_gone
    # The reclaimed-worktree case. The branch is still in the standing repo, and a
    # committed diff does not care what the checkout is dirty with — so there IS an
    # honest local answer, and refusing here would strand reviewers the way the false
    # STALE did.
    with_world(worktree: false) do |projects, primary, _none|
      git!(primary, "update-ref", "refs/remotes/origin/accepted", "release")
      git!(primary, "checkout", "-q", "-b", "feat/#{SLUG}")
      PR_CODE.each { |rel| write(primary, rel, "# #{rel}\n") }
      git!(primary, "add", *PR_CODE) # NOT -A: the dirt must stay UNCOMMITTED, or the
      git!(primary, "commit", "-qm", "feat") # fixture hides the very file under test
      git!(primary, "checkout", "-q", "release") # back to the wrong-root state
      assert_path_exists File.join(primary, PRIMARY_DIRT), "the dirt must survive as untracked scratch"

      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal "branch", verdict["diff_source"],
                   "the committed branch diff is the honest source when no worktree exists"
    end
  end

  def test_integration_fails_closed_when_no_tree_here_can_show_the_diff
    # No worktree, no branch, PR unreadable — and a dirty primary sitting right there
    # offering a convincing doc-only answer. There is no honest verdict available, so
    # the exemption must be REFUSED rather than taken from the nearest tree.
    with_world(worktree: false) do |projects, primary, _none|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_equal 1, code
      refute verdict["ready"]
      refute verdict["exempt"], "an unobservable diff is not a doc-only diff"

      blame = verdict["errors"].join(" ")
      assert_includes blame, primary, "name the checkout whose tree was refused"
      assert_includes blame, "feat/#{SLUG}", "and the branch it needed instead"
      refute_includes blame, PRIMARY_DIRT,
                      "the primary's dirt must not even be quoted as evidence — it was never read"
    end
  end

  # ── [integration] the foreign tree is off limits to CONTENT readers too ────

  def test_integration_the_gem_guard_never_reads_a_foreign_checkouts_gemfile
    # The same wrong-tree mistake, one gate over, failing the other way — a false
    # BLOCK instead of a false pass. The gem-publish guard READS Gemfile +
    # Gemfile.lock CONTENT from the root, so from a foreign checkout it compares two
    # unrelated trees: a reviewer who happens to be mid `bundle update` on their
    # primary would see their own half-finished bump reported as THIS task's blocker.
    # The diff here comes from the PR (repo-correct), so nothing but the trust rule
    # keeps the guard away from the local pair.
    with_world(worktree: false, dirt: []) do |projects, primary, _none|
      write(primary, "Gemfile", %(source "https://rubygems.org"\ngem "studio-engine", "0.99.0"\n))
      write(primary, "Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (0.32.1)\n")
      git!(primary, "add", "Gemfile", "Gemfile.lock")
      git!(primary, "commit", "-qm", "lockfile")
      write(primary, "Gemfile", %(source "https://rubygems.org"\ngem "studio-engine", "1.99.0"\n)) # dirty bump

      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review",
                                 pr_files: "app/services/widget.rb")

      assert_equal 1, code, "the code PR is still gated for a shape — that part is unchanged"
      blame = verdict["errors"].join(" ")
      assert_match(/ships a code diff/, blame)
      refute_match(/Gemfile\.lock pins/, blame,
                   "the reviewer's own mid-bump Gemfile is not this task's blocker")
    end
  end

  # ── [integration] multi-repo: disambiguate, or refuse to guess ─────────────

  # Two repos, one slug, one PR. The task's worktree exists under BOTH — the normal
  # shape of a multi-repo task — and only the PR says which one this verdict is about.
  def with_multi_repo_world
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "hub"))
      git!(primary, "checkout", "-q", "-b", "release")
      write(primary, PRIMARY_DIRT, "unrelated local scratch\n")

      # Sorts FIRST, and ships only prose — the tree a blind pick would grab, and the
      # one that would hand the code PR a doc-only exemption all over again.
      docs_side = build_task_tree(File.join(projects, "aaa-app", ".worktrees", SLUG),
                                  files: ["docs/agents/notes.md"])
      # Sorts LAST, and is the repo the PR actually lives in.
      code_side = build_task_tree(File.join(projects, "zzz-app", ".worktrees", SLUG), files: PR_CODE)
      yield projects, primary, docs_side, code_side
    end
  end

  def test_integration_multi_repo_resolves_the_repo_the_pr_names
    with_multi_repo_world do |projects, primary, docs_side, code_side|
      verdict, code, = dor_check(chore_task(repo: "zzz-app"), primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal code_side, verdict["code_root"], "devops.pr_url names the repo under gate"
      refute_equal docs_side, verdict["code_root"],
                   "the alphabetically-first worktree is a coin flip, not an answer"
    end
  end

  def test_integration_multi_repo_refuses_to_guess_when_the_pr_names_no_worktree
    # A blank/foreign pr_url leaves nothing to break the tie. Picking the first
    # candidate would re-create the wrong-tree bug one repo over — and here it would
    # land on the docs-only tree and pass the code PR. Refuse instead.
    with_multi_repo_world do |projects, primary, _docs_side, _code_side|
      verdict, code, stderr = dor_check(chore_task(pr: false), primary, projects, "--gate-role", "review")

      assert_equal 1, code
      refute verdict["ready"]
      refute verdict["exempt"], "an unresolved multi-repo task must not collect a doc-only exemption"
      assert_includes stderr, "AMBIGUOUS", "the refusal to guess must be announced"
      assert_includes stderr, "aaa-app", "naming every candidate is what makes the refusal actionable"
      assert_includes stderr, "zzz-app"
    end
  end

  # ── [integration] the rung ladder is per-repo ──────────────────────────────

  def test_integration_a_repo_with_no_accepted_rung_still_resolves_its_own_base
    # moms-app-style: no `accepted` branch, only `main`. The resolver must fall
    # through the ladder in the TASK's repo instead of assuming the hub's rungs —
    # otherwise the committed diff comes back empty and the gate quietly reverts to
    # "nothing observed" on a repo that simply sits on a different rung.
    with_world(base_rung: "main") do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal tree, verdict["code_root"]
    end
  end
end
