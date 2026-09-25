# frozen_string_literal: true

# Regression for the bin/dor-check TASK-ROOT GUARD.
#   ruby -Itest test/lib/dor_check_root_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE BUG (2026-07-14). `bin/dor-check <task>` run from the PRIMARY checkout, for a
# task whose code lives in a worktree, graded the PRIMARY's tree. At the time the
# symptom was a false STALE on the cert fingerprint (a git TREE hash is
# content-addressed, so a foreign checkout can never match one) — 6 of 6 tasks in one
# day, including ones certified green 90 seconds earlier — and an agent that hits an
# unexplainable STALE stops, so it stranded finished tasks in `building`.
#
# The cert fingerprint retired with the receipts (/tasks/dor-reads-settled-ci-verdict:
# the suite evidence is the PR's settled green CI, read for the PR head wherever the
# gate stands). The guard did not retire with it, because the DIFF still roots here
# and fails in the DANGEROUS direction (a false PASS — test/lib/
# dor_check_review_diff_rooting_test.rb), and because ONE fingerprint-bound lane is
# still graded: the `test-only` control stamp, which takes the same rooting.
#
# bin/lib/cert_root_guard.rb already existed to cure exactly this, and BOTH cert
# runners require it. dor-check — the one command in the family that READS — never
# consulted it until 2026-07-14.
#
# The invariant these tests assert (positively, not by blacklisting messages):
#
#     dor-check grades the TASK's tree. Never the tree you happen to stand in.

require "minitest/autorun"
require_relative "../../bin/lib/tree_fingerprint"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/control_replay"

load File.expand_path("../../bin/lib/tree_fingerprint.rb", __dir__)

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
  #                                           carrying the code under review.
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
  # variable under test is WHICH TREE the gate grades. The suite evidence is the
  # injected GREEN CI (DOR_CHECK_CI_STATUS), which reads the same from any root — so a
  # verdict that changes with the cwd is the guard's subject, not the CI gate's.
  def task_json(slug: SLUG, checks: nil)
    {
      "slug" => slug, "title" => "Task X",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend",
        "acceptance" => ["grade the task's tree"],
        "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["devops"],
        "test_plan" => ["[unit] guard", "[integration] dor-check"],
        "post_deploy_cmd" => "none",
        "checks_run" => checks || [
          "[unit] bin/rails test test/lib/cert_root_guard_test.rb",
          "[integration] bin/rails test test/lib/dor_check_root_guard_test.rb"
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
      env = OutboundSeams.env(
        "DOR_CHECK_DIFF_ROOT" => nil,        # implicit root: the whole point
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "app/services/widget.rb",
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_PROJECTS_DIR" => projects
      )
      out = IO.popen(env, "#{BIN} #{task['slug']} --file #{path} --json #{args.join(' ')} 2>#{err}",
                     chdir: cwd, &:read)
      [JSON.parse(out), $?.exitstatus, File.read(err)]
    end
  end

  # ── [integration] THE BUG: dor-check from a foreign root ────────────────────

  def test_integration_the_gate_re_roots_at_the_tasks_tree_when_run_from_the_primary
    # THE MUTATION. The exact reproduction: a task whose tree is the worktree, graded
    # by dor-check run from the PRIMARY checkout. Pre-fix every tree-reading check
    # described the primary.
    with_projects do |projects, primary, tree|
      verdict, code, = dor_check(task_json, primary, projects)

      # THE POSITIVE INVARIANT: the verdict is about the TASK's tree.
      assert_equal tree, verdict["code_root"], "dor-check must root at the task's tree"
      refute_equal primary, verdict["code_root"], "grading the checkout you STAND in is the bug itself"

      assert verdict["ready"], "a satisfied task must read ready from anywhere: #{verdict['errors']}"
      assert_equal 0, code
      assert_equal "green", verdict.dig("suite_evidence", "state")
    end
  end

  def test_integration_the_re_root_is_announced_never_silent
    # cert_root_guard.rb warns that a SILENT chdir is its own hazard: the tool and
    # the operator end up believing different things about which code was judged. So
    # the resolve must SAY SO, and must name BOTH roots — where you are, where it went.
    with_projects do |projects, primary, tree|
      _verdict, _code, stderr = dor_check(task_json, primary, projects)

      refute_empty stderr, "a re-root that says nothing is the hazard the guard warns about"
      assert_includes stderr, primary, "the banner must name the root you were standing in"
      assert_includes stderr, tree, "the banner must name the root it moved to"
    end
  end

  def test_integration_running_from_the_task_worktree_still_passes_silently
    # The correct invocation must be untouched — and QUIET. If the guard fired here
    # it would be crying wolf on the normal path, which is how guards get ignored.
    with_projects do |projects, _primary, tree|
      verdict, code, stderr = dor_check(task_json, tree, projects)

      assert_equal 0, code
      assert verdict["ready"], verdict["errors"].to_s
      assert_equal tree, verdict["code_root"]
      refute_includes stderr, "RE-ROOTING", "the task's own worktree must not trip the guard"
    end
  end

  # ── [integration] the one fingerprint-bound lane left: the control stamp ────
  #
  # The `test-only` shape's EXECUTED control (`[control@<fp>]`, bin/control-check)
  # is graded against a tree hash exactly as the certs were, so it inherits the
  # false-STALE bug the certs had: run from the primary, the primary's hash can never
  # equal the stamp's. The guard's re-root is what keeps that lane honest, and this
  # is the test that would have gone red on 2026-07-14.

  def control_task(fingerprint)
    task = task_json(checks: ["[control@#{fingerprint}] #{ControlReplay::NECESSARY} — replayed " \
                              "test/models/widget_test.rb against current production code"])
    task["metadata"]["devops"].merge!(
      "shape" => "test-only", "test_plan" => ["[control] replay the pre-change test"]
    )
    task
  end

  def with_test_only_projects
    with_projects do |projects, primary, tree|
      write(tree, "test/models/widget_test.rb", "assert true\n")
      git!(tree, "add", "-A")
      git!(tree, "commit", "-qm", "test change")
      yield projects, primary, tree
    end
  end

  def control_check(task, cwd, projects)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = OutboundSeams.env(
        "DOR_CHECK_DIFF_ROOT" => nil, "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "test/models/widget_test.rb",
        "DOR_CHECK_CI_STATUS" => "green", "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_PROJECTS_DIR" => projects
      )
      out = IO.popen(env, "#{BIN} #{task['slug']} --file #{path} --json 2>/dev/null", chdir: cwd, &:read)
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def test_integration_a_fresh_control_stamp_reads_fresh_from_the_primary
    with_test_only_projects do |projects, primary, tree|
      stamp_fp = TreeFingerprint.working_tree(tree)
      refute_equal stamp_fp, TreeFingerprint.working_tree(primary),
                   "the two checkouts must hash differently, or this test proves nothing"

      verdict, code = control_check(control_task(stamp_fp), primary, projects)

      assert_equal 0, code, "a control stamped in the task's tree must grade FRESH from the primary: " \
                            "#{verdict['errors']}"
      assert_equal tree, verdict["code_root"]
    end
  end

  def test_integration_a_genuinely_stale_control_stamp_still_refuses
    # The guard must not become a rubber stamp: re-rooting fixes WHERE we look, not
    # WHETHER the code changed. Edit the worktree after stamping → still STALE.
    with_test_only_projects do |projects, primary, tree|
      stamp_fp = TreeFingerprint.working_tree(tree)
      write(tree, "test/models/widget_test.rb", "assert true # edited after the control ran\n")

      verdict, code = control_check(control_task(stamp_fp), primary, projects)

      assert_equal 1, code, "an edited tree is REALLY stale — re-rooting must not excuse it"
      assert_match(/recorded control is STALE/, verdict["errors"].join(" "))
    end
  end

  # ── [integration] scope: the guard leaves the other lanes alone ─────────────

  def test_integration_an_explicit_diff_root_bypasses_the_guard
    # DOR_CHECK_DIFF_ROOT is the caller DECLARING a root (the CI/test seam, and the
    # documented manual reviewer workaround) — exactly as FAST_CHECK_ROOT /
    # FULL_SUITE_ROOT bypass the guard for the cert writers. It must still win.
    with_projects do |projects, primary, tree|
      Dir.mktmpdir do |d|
        path = File.join(d, "task.json")
        File.write(path, JSON.generate(task_json))
        env = OutboundSeams.env(
          "DOR_CHECK_DIFF_ROOT" => tree, # declared: grade THIS tree
          "DOR_CHECK_CHANGED_FILES" => nil, "DOR_CHECK_CI_STATUS" => "green",
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
    # diff and no CI, so the guard must stay out of its way — refusing a task for
    # having no worktree BEFORE it is allowed to start work would be a deadlock.
    with_projects(worktree: false) do |projects, primary, _none|
      task = task_json(checks: [])
      verdict, code, stderr = dor_check(task, primary, projects, "--gate", "build")

      assert_equal 0, code, verdict["errors"].to_s
      assert verdict["ready"]
      refute_includes stderr, "RE-ROOTING"
    end
  end
end
