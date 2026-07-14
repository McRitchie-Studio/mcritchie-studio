# frozen_string_literal: true

# Regression for the bin/dor-check TASK-ROOT GUARD and the STALE fingerprint DELTA.
#   ruby -Itest test/lib/dor_check_root_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE BUG (2026-07-14). `bin/dor-check <task>` run from the PRIMARY checkout, for a
# task whose code lives in a worktree, reported "fast-cert: STALE (certified for
# older code)" for a cert that was perfectly fresh. The identical command run from
# inside the task's worktree reported GREEN. It did this for 6 of 6 tasks in one
# day, including ones certified green 90 seconds earlier.
#
# The mechanism: a cert's fingerprint is a git TREE hash (content-addressed), so a
# DIFFERENT checkout's tree can never equal it. A foreign root doesn't read as
# "wrong root" — it reads as STALE. And an agent that hits an unexplainable STALE
# stops working, so the false STALE stranded finished tasks in `building`.
#
# bin/lib/cert_root_guard.rb already existed to cure exactly this, and BOTH cert
# runners require it. dor-check — the one command in the family that READS the
# evidence — never consulted it.
#
# The invariant these tests assert (positively, not by blacklisting messages):
#
#     dor-check grades the TASK's tree. Never the tree you happen to stand in.
#
# and, when a cert really IS stale, that the refusal NAMES the delta — the recorded
# fingerprint vs the current one vs the root — so "STALE" carries its own diagnosis
# instead of being a riddle the next agent has to re-derive.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckRootGuardTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "task-x"

  # ── git + projects-root fixtures ───────────────────────────────────────────

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def init_repo(dir, branch: nil)
    FileUtils.mkdir_p(dir)
    real = File.realpath(dir)
    git!(real, "init", "-q")
    git!(real, "config", "user.email", "t@t.co")
    git!(real, "config", "user.name", "T")
    write(real, "README.md", "base\n")
    git!(real, "add", "-A")
    git!(real, "commit", "-qm", "init")
    git!(real, "checkout", "-q", "-b", branch) if branch
    real
  end

  # The world the bug lives in:
  #
  #   <projects>/myapp/                     ← the PRIMARY checkout (on `release`).
  #                                           NOT the task's tree. This is where the
  #                                           agent is standing when it runs dor-check.
  #   <projects>/myapp/.worktrees/task-x/   ← the task's tree (branch feat/task-x),
  #                                           carrying the code that was certified.
  #
  # `worktree:` false omits the worktree entirely (the reclaimed-worktree case).
  # Yields [projects, primary, worktree_or_nil].
  def with_projects(worktree: true)
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"), branch: "release")

      tree = nil
      if worktree
        tree = init_repo(File.join(projects, "myapp", ".worktrees", SLUG), branch: "feat/#{SLUG}")
        write(tree, "app/services/widget.rb", "class Widget; end\n")
        git!(tree, "add", "-A")
        git!(tree, "commit", "-qm", "feat")
      end
      yield projects, primary, tree
    end
  end

  # ── the task fixture ───────────────────────────────────────────────────────

  # A backend task whose spec, tiers, and post-deploy are all satisfied, so the ONLY
  # variable under test is WHICH TREE the gate grades. checks_run carries a FULL cert
  # (full-suite + rubocop) for `fp` — the full route needs no CI, keeping the CI gate
  # out of these assertions entirely.
  def task_json(fp, slug: SLUG)
    {
      "slug" => slug, "title" => "Task X",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend",
        "acceptance" => ["grade the task's tree"],
        "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["devops"],
        "test_plan" => ["[unit] guard", "[integration] dor-check"],
        "post_deploy_cmd" => "none",
        "checks_run" => [
          "[unit] bin/rails test test/lib/cert_root_guard_test.rb",
          "[integration] bin/rails test test/lib/dor_check_root_guard_test.rb",
          "[full-suite@#{fp}] bin/rails test (204 runs, 0 failures)",
          "[rubocop@#{fp}] bin/rubocop (clean)"
        ]
      } }
    }
  end

  # Run bin/dor-check FROM `cwd` (an implicit root — the production path; NO
  # DOR_CHECK_DIFF_ROOT, which would be an explicit caller declaration and bypass the
  # guard by design). DOR_CHECK_PROJECTS_DIR points the worktree glob at the temp
  # projects root. Returns [verdict_hash, exit_code, stderr].
  def dor_check(task, cwd, projects, *args)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      err = File.join(d, "stderr.txt")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => nil,        # implicit root: the whole point
        "DOR_CHECK_SUITE_EVIDENCE" => nil,   # real git fingerprint path
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "app/services/widget.rb",
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_PROJECTS_DIR" => projects
      )
      out = IO.popen(env, "#{BIN} #{task['slug']} --file #{path} --json #{args.join(' ')} 2>#{err}",
                     chdir: cwd, &:read)
      [JSON.parse(out), $?.exitstatus, File.read(err)]
    end
  end

  # ── [unit] FullSuiteGate.recorded_fingerprints ─────────────────────────────
  # The delta's raw material: what the evidence was certified FOR. lane_status
  # collapses that to :fresh/:stale — a verdict with its evidence thrown away.

  def test_unit_recorded_fingerprints_reads_each_lanes_tags
    checks = [
      "[unit] bin/rails test",                       # author tier tag — NOT evidence
      "[full-suite-bypass] some reason",             # author record  — NOT evidence
      "[full-suite@#{'a' * 40}] bin/rails test",
      "[rubocop@#{'b' * 40}] bin/rubocop"
    ]
    assert_equal ["a" * 40], FullSuiteGate.recorded_fingerprints(checks, "full-suite")
    assert_equal ["b" * 40], FullSuiteGate.recorded_fingerprints(checks, "rubocop")
    assert_empty FullSuiteGate.recorded_fingerprints(checks, "fast-cert")
  end

  def test_unit_recorded_fingerprints_is_empty_for_no_evidence
    assert_empty FullSuiteGate.recorded_fingerprints(["[unit] x", "[integration] y"], "full-suite")
    assert_empty FullSuiteGate.recorded_fingerprints([], "full-suite")
    assert_empty FullSuiteGate.recorded_fingerprints(nil, "full-suite")
  end

  def test_unit_evaluate_carries_recorded_alongside_the_current_fingerprint
    # The two halves of the delta, in one verdict: what it WAS certified for
    # (recorded) and what the code IS (fingerprint).
    with_projects do |_projects, _primary, tree|
      current = FullSuiteGate.fingerprint(tree)
      stale_fp = "c" * 40
      verdict = FullSuiteGate.evaluate(checks: ["[full-suite@#{stale_fp}] x"], root: tree)

      assert_equal current, verdict[:fingerprint]
      assert_equal [stale_fp], verdict[:recorded]["full-suite"]
      assert_equal :stale, verdict[:lanes]["full-suite"]
      refute_equal stale_fp, current, "the fixture must actually be stale (guards the test itself)"
    end
  end

  def test_unit_evaluate_carries_empty_recorded_on_the_injected_and_bypass_paths
    # These verdicts never read the checks, so every lane must still be INDEXABLE —
    # an empty list, not a missing key — or the delta formatter blows up on nil.
    %w[ok missing stale unverifiable].each do |token|
      verdict = FullSuiteGate.evaluate(checks: [], root: ".", injected: token)
      FullSuiteGate::EVIDENCE_LANES.each { |lane| assert_empty verdict[:recorded][lane], token }
    end
    bypass = FullSuiteGate.evaluate(checks: ["[full-suite-bypass] why"], root: ".")
    FullSuiteGate::EVIDENCE_LANES.each { |lane| assert_empty bypass[:recorded][lane] }
  end

  # ── [integration] THE BUG: dor-check from a foreign root ────────────────────

  def test_integration_the_false_stale_is_gone_when_run_from_the_primary
    # THE MUTATION. The exact reproduction: a cert taken in the task's worktree,
    # graded by dor-check run from the PRIMARY checkout. Pre-fix this was a
    # guaranteed STALE — the primary's tree hash can never equal the worktree's.
    with_projects do |projects, primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      primary_fp = FullSuiteGate.fingerprint(primary)
      refute_equal cert_fp, primary_fp,
                   "the two checkouts must hash differently, or this test proves nothing"

      verdict, code, stderr = dor_check(task_json(cert_fp), primary, projects)

      # THE POSITIVE INVARIANT: the verdict is about the TASK's tree.
      assert_equal tree, verdict["code_root"], "dor-check must root at the task's tree"
      assert_equal cert_fp, verdict.dig("full_suite", "fingerprint"),
                   "the cert must be graded against the tree it was taken in"
      refute_equal primary_fp, verdict.dig("full_suite", "fingerprint"),
                   "grading the checkout you STAND in is the bug itself"

      assert verdict["ready"], "a fresh cert must read fresh from anywhere: #{verdict['errors']}"
      assert_equal 0, code
      assert_equal "fresh", verdict.dig("full_suite", "lanes", "full-suite")
      assert_equal "full", verdict.dig("full_suite", "route")
    end
  end

  def test_integration_the_re_root_is_announced_never_silent
    # cert_root_guard.rb warns that a SILENT chdir is its own hazard: the tool and
    # the operator end up believing different things about which code was judged. So
    # the resolve must SAY SO, and must name BOTH roots — where you are, where it went.
    with_projects do |projects, primary, tree|
      _verdict, _code, stderr = dor_check(task_json(FullSuiteGate.fingerprint(tree)), primary, projects)

      refute_empty stderr, "a re-root that says nothing is the hazard the guard warns about"
      assert_includes stderr, primary, "the banner must name the root you were standing in"
      assert_includes stderr, tree, "the banner must name the root it moved to"
    end
  end

  def test_integration_running_from_the_task_worktree_still_passes_silently
    # The correct invocation must be untouched — and QUIET. If the guard fired here
    # it would be crying wolf on the normal path, which is how guards get ignored.
    with_projects do |projects, _primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      verdict, code, stderr = dor_check(task_json(cert_fp), tree, projects)

      assert_equal 0, code
      assert verdict["ready"], verdict["errors"].to_s
      assert_equal tree, verdict["code_root"]
      assert_equal cert_fp, verdict.dig("full_suite", "fingerprint")
      refute_includes stderr, "RE-ROOTING", "the task's own worktree must not trip the guard"
    end
  end

  def test_integration_a_genuinely_stale_cert_still_refuses_from_the_worktree
    # The guard must not become a rubber stamp: re-rooting fixes WHERE we look, not
    # WHETHER the code changed. Edit the worktree after certifying → still STALE.
    with_projects do |projects, primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      write(tree, "app/services/widget.rb", "class Widget; def new_thing; end; end\n")
      current_fp = FullSuiteGate.fingerprint(tree)
      refute_equal cert_fp, current_fp

      verdict, code, = dor_check(task_json(cert_fp), primary, projects)

      assert_equal 1, code, "an edited tree is REALLY stale — re-rooting must not excuse it"
      refute verdict["ready"]
      assert_equal "stale", verdict.dig("full_suite", "lanes", "full-suite")
      assert_equal current_fp, verdict.dig("full_suite", "fingerprint"),
                   "and it is graded against the TASK's tree, not the primary's"
    end
  end

  # ── [integration] remedy 2: no worktree on disk, but the branch is here ─────

  def test_integration_falls_back_to_the_branch_tree_when_the_worktree_is_gone
    # The reclaimed-worktree case. The branch still lives in the repo, and a git tree
    # hash is content-addressed, so the branch's committed ^{tree} IS the tree the
    # builder certified. Grade against that rather than the checkout we stand in.
    with_projects(worktree: false) do |projects, primary, _none|
      git!(primary, "checkout", "-q", "-b", "feat/#{SLUG}")
      write(primary, "app/services/widget.rb", "class Widget; end\n")
      git!(primary, "add", "-A")
      git!(primary, "commit", "-qm", "feat")
      branch_tree = IO.popen(["git", "-C", primary, "rev-parse", "feat/#{SLUG}^{tree}"], &:read).strip
      git!(primary, "checkout", "-q", "release") # back to the wrong-root state

      verdict, code, stderr = dor_check(task_json(branch_tree), primary, projects)

      assert_equal 0, code, "the branch tree can grade the cert even with no worktree: #{verdict['errors']}"
      assert verdict["ready"]
      assert_equal branch_tree, verdict.dig("full_suite", "fingerprint")
      assert_includes stderr, "RE-ROOTING", "the fingerprint re-root is announced too"
    end
  end

  # Remedy 2 is the OTHER lane where the fingerprint comes from an override — so it
  # is the other lane where the announcement could name a root it never hashed. Same
  # invariant as the review lane (test/lib/dor_check_review_fingerprint_test.rb):
  # recompute the root the gate NAMES and you get the hash the gate PRINTS.
  #
  # A genuinely STALE cert here, so the reporting path actually renders. Pre-fix this
  # printed "(root: <primary>)" beside a hash taken from feat/task-x^{tree} — and the
  # primary's working tree hashes to a THIRD number, so an agent who followed the
  # message to that root and recomputed found neither hash and had no way to proceed.
  def test_integration_remedy_2_names_the_branch_tree_it_hashed_not_the_primary
    with_projects(worktree: false) do |projects, primary, _none|
      git!(primary, "checkout", "-q", "-b", "feat/#{SLUG}")
      write(primary, "app/services/widget.rb", "class Widget; end\n")
      git!(primary, "add", "-A")
      git!(primary, "commit", "-qm", "feat")
      branch_tree = IO.popen(["git", "-C", primary, "rev-parse", "feat/#{SLUG}^{tree}"], &:read).strip
      git!(primary, "checkout", "-q", "release")
      primary_tree = FullSuiteGate.fingerprint(primary) # the third number
      refute_equal branch_tree, primary_tree

      verdict, code, = dor_check(task_json("f" * 40), primary, projects) # cert for neither tree

      assert_equal 1, code, "a cert matching NO tree is stale — the branch tree is graded, not excused"
      fs = verdict["full_suite"]
      assert_equal "branch-tree", fs["fingerprint_source"]
      assert_equal branch_tree, fs["fingerprint"]
      assert_equal "feat/#{SLUG}^{tree}", fs["fingerprint_root"],
                   "no origin in this fixture, so the LOCAL branch is what resolved — and what must be named"
      assert_equal primary, fs["fingerprint_repo"], "the repo the ref resolves in"

      # THE INVARIANT, by recomputation: the named root reproduces the printed hash.
      recomputed = IO.popen(["git", "-C", fs["fingerprint_repo"], "rev-parse", fs["fingerprint_root"]], &:read).strip
      assert_equal fs["fingerprint"], recomputed,
                   "the root the gate names must be the root it hashed — no third number"

      blame = verdict["errors"].join(" ")
      assert_includes blame, "feat/#{SLUG}^{tree}", "name the ref that produced the hash"
      refute_includes blame, primary_tree[0, 12], "the primary's tree hash graded nothing and must not appear"
    end
  end

  # ── [integration] remedy 3: nothing here can grade it → refuse, TRUTHFULLY ──

  def test_integration_refuses_when_no_tree_here_can_grade_the_cert
    # No worktree, no branch: there is no honest verdict available. The old code
    # graded the foreign tree anyway and called the result STALE — a LYING exit 1.
    # This is a TRUTHFUL exit 1: same code, an error that names the actual problem.
    with_projects(worktree: false) do |projects, primary, _none|
      verdict, code, = dor_check(task_json("d" * 40), primary, projects)

      assert_equal 1, code
      refute verdict["ready"]

      # THE POSITIVE INVARIANT: it did not grade ANY tree. Not "it didn't say the
      # word STALE" — the message is free to explain what a false STALE is. The
      # property is that no fingerprint was computed and no lane was scored, because
      # there was no honest tree to score against. A foreign tree graded anyway is
      # the bug, whatever the wording.
      assert_nil verdict["full_suite"], "a cert it cannot LOOK at must not be graded at all"

      blame = verdict["errors"].join(" ")
      assert_match(/root guard/i, blame)
      assert_includes blame, primary, "it must name the root that cannot grade the cert"
      assert_includes blame, "feat/#{SLUG}", "and the branch it needed"
    end
  end

  # ── [integration] the STALE message names the fingerprint DELTA ─────────────
  # PR #361's guardrail 2 (written, never landed). "STALE" alone is a riddle: it
  # reads as "you edited since certifying" even when the true cause is a wrong root.
  # The two want opposite fixes, so the message must let you tell them apart.

  def test_integration_stale_refusal_prints_the_fingerprint_delta
    with_projects do |projects, _primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      write(tree, "app/services/widget.rb", "edited after certifying\n")
      current_fp = FullSuiteGate.fingerprint(tree)
      refute_equal cert_fp, current_fp, "the edit must move the fingerprint (guards the test itself)"

      verdict, code, = dor_check(task_json(cert_fp), tree, projects)
      assert_equal 1, code
      blame = verdict["errors"].join(" ")

      assert_match(/certified for @#{cert_fp[0, 12]}/, blame, "name what the evidence was certified FOR")
      assert_match(/@#{current_fp[0, 12]}/, blame, "name what the code IS now")
      assert_includes blame, tree, "and name the root the current hash was read from"

      # This lane hashed a WORKING TREE, so it must say so — and must NOT call it
      # HEAD. The fingerprint includes uncommitted edits (that is WHY it moved here),
      # so an agent who verifies "@#{current_fp[0, 12]}" with `git rev-parse
      # HEAD^{tree}` gets a different hash and concludes the gate is broken.
      assert_equal "working-tree", verdict.dig("full_suite", "fingerprint_source")
      assert_equal tree, verdict.dig("full_suite", "fingerprint_root")
      assert_equal current_fp, FullSuiteGate.fingerprint(verdict.dig("full_suite", "fingerprint_root")),
                   "the named root must recompute to the printed hash"
      refute_includes blame, "HEAD is now", "the working-tree fingerprint is not HEAD's tree"
    end
  end

  def test_integration_recorded_fingerprints_are_machine_readable_in_json
    # The delta, for the monitors: a heartbeat comparing two runs can now SEE that
    # they graded different code instead of reporting a mysterious STALE twice.
    with_projects do |projects, _primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      write(tree, "app/services/widget.rb", "edited\n")

      verdict, code, = dor_check(task_json(cert_fp), tree, projects)
      assert_equal 1, code
      assert_equal [cert_fp], verdict.dig("full_suite", "recorded", "full-suite")
      assert_equal [cert_fp], verdict.dig("full_suite", "recorded", "rubocop")
      refute_equal cert_fp, verdict.dig("full_suite", "fingerprint")
    end
  end

  # ── [integration] scope: the guard leaves the other lanes alone ─────────────

  def test_integration_an_explicit_diff_root_bypasses_the_guard
    # DOR_CHECK_DIFF_ROOT is the caller DECLARING a root (the CI/test seam, and the
    # documented manual reviewer workaround) — exactly as FAST_CHECK_ROOT /
    # FULL_SUITE_ROOT bypass the guard for the cert writers. It must still win.
    with_projects do |projects, primary, tree|
      cert_fp = FullSuiteGate.fingerprint(tree)
      Dir.mktmpdir do |d|
        path = File.join(d, "task.json")
        File.write(path, JSON.generate(task_json(cert_fp)))
        env = SessionEnv.neutralized(
          "DOR_CHECK_DIFF_ROOT" => tree, # declared: grade THIS tree
          "DOR_CHECK_SUITE_EVIDENCE" => nil, "DOR_CHECK_CHANGED_FILES" => nil,
          "DOR_CHECK_PR_FILES" => "app/services/widget.rb",
          "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_PROJECTS_DIR" => projects
        )
        out = IO.popen(env, "#{BIN} #{SLUG} --file #{path} --json 2>/dev/null", chdir: primary, &:read)
        verdict = JSON.parse(out)

        assert_equal 0, $?.exitstatus, "the declared root is the task's tree, so this passes"
        assert_equal tree, verdict["code_root"]
      end
    end
  end

  def test_integration_the_build_gate_never_roots_at_a_tree
    # At `designed` there is no branch and no worktree yet. The build gate reads no
    # fingerprint, so the guard must stay out of its way — refusing a task for having
    # no worktree BEFORE it is allowed to start work would be a deadlock.
    with_projects(worktree: false) do |projects, primary, _none|
      task = task_json("e" * 40)
      task["metadata"]["devops"]["checks_run"] = []
      verdict, code, stderr = dor_check(task, primary, projects, "--gate", "build")

      assert_equal 0, code, verdict["errors"].to_s
      assert verdict["ready"]
      refute_includes stderr, "RE-ROOTING"
    end
  end
end
