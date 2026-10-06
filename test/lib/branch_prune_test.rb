# frozen_string_literal: true

# BranchPrune — the merged-branch pruner bin/release archive drives.
#
#   bin/rails test test/lib/branch_prune_test.rb
#
# The remote is a local bare repo in a tmpdir; `gh`, the board and the token broker
# are stub scripts. No real remote, board or GitHub App is touched.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require_relative "../support/session_env"
require File.expand_path("../../bin/lib/branch_prune", __dir__)

class BranchPruneTest < Minitest::Test
  BIN = File.expand_path("../../bin/prune-branches", __dir__)

  def plan(remote, merged: remote.keys, prs: [], desks: [], slugs: [], branches: [])
    BranchPrune.plan(remote: remote, merged: Set.new(merged), open_pr_heads: Set.new(prs),
                     desk_branches: Set.new(desks), done_slugs: Set.new(slugs), done_branches: Set.new(branches))
  end

  # --- the plan ---------------------------------------------------------------

  def test_unit_selects_a_merged_feat_branch_whose_task_is_done
    p = plan({ "feat/a" => "1", "feat/b" => "2" }, slugs: ["a"], branches: ["feat/b"])
    assert_equal ["feat/a", "feat/b"], p.names
    assert_equal "1", p.prune.first[:sha]
  end

  def test_unit_never_selects_the_protected_rungs_or_a_non_feat_branch
    remote = { "main" => "1", "release" => "1", "accepted" => "1", "fix/x" => "1", "feat/main" => "1" }
    p = plan(remote, slugs: %w[main release accepted x])
    assert_equal ["feat/main"], p.names, "only feat/* is ever a candidate"
    assert_empty p.skipped
  end

  def test_unit_refuses_an_unmerged_branch
    p = plan({ "feat/a" => "1" }, merged: [], slugs: ["a"])
    assert_empty p.names
    assert_equal({ "not merged into main" => 1 }, p.skipped)
  end

  def test_unit_refuses_a_branch_with_an_open_pr
    p = plan({ "feat/a" => "1" }, prs: ["feat/a"], slugs: ["a"])
    assert_empty p.names
    assert_equal({ "open PR" => 1 }, p.skipped)
  end

  def test_unit_refuses_a_branch_bound_to_a_desk
    p = plan({ "feat/a" => "1" }, desks: ["feat/a"], slugs: ["a"])
    assert_empty p.names
    assert_equal({ "bound to a desk" => 1 }, p.skipped)
  end

  def test_unit_refuses_a_branch_whose_task_is_not_done
    p = plan({ "feat/a" => "1" })
    assert_empty p.names
    assert_equal({ "task not shipped or archived" => 1 }, p.skipped)
  end

  # --- against a real (local) remote --------------------------------------------

  def test_integration_delete_is_leased_on_the_planned_tip
    with_remote do |work, _origin|
      sha = rev(work, "feat/done")
      commit(work, "feat/done", "moved") # the branch moves after the plan saw it
      git(work, "push", "-q", "origin", "feat/done")

      stale = BranchPrune::Plan.new(prune: [{ name: "feat/done", sha: sha }], skipped: {}, refusal: nil)
      removed, refusal = BranchPrune.apply!(stale, work, env: {})
      assert_empty removed, "a moved branch is refused by its lease"
      assert_match(/the delete push failed/, refusal, "a refused push is a refusal, not 'deleted 0'")
      assert_includes remote_heads(work), "feat/done"
    end
  end

  def test_integration_cli_refuses_when_open_prs_cannot_be_read
    with_remote do |work, _origin|
      out, status = run_cli(work, gh_exit: 1)
      refute status.success?
      assert_match(/refused: open PRs could not be read/, out)
      assert_equal 0, BranchPrune.parse_summary(out)[:count]
    end
  end

  # [control] rev bites on a ref that does not resolve, rather than returning its name.
  def test_integration_rev_raises_on_a_ref_that_does_not_resolve
    with_remote do |work, _origin|
      error = assert_raises(RuntimeError) { rev(work, "feat/no-such-branch") }
      assert_match(/feat\/no-such-branch.*#{Regexp.escape(work)}.*exit 128/, error.message)
    end
  end

  # Each read refuses on failure rather than reading empty. A failed desk read that
  # read as "no desks" would make a desk's checked-out branch deletable.
  def test_unit_each_git_read_refuses_outside_a_repository
    Dir.mktmpdir do |not_a_repo|
      assert_match(/desks could not be read \(git worktree list/, BranchPrune.desk_branches(not_a_repo).last)
      assert_match(/origin's branches could not be read/, BranchPrune.remote_branches(not_a_repo).last)
      assert_match(/the merged set could not be read/, BranchPrune.merged_into_main(not_a_repo).last)
      assert_nil BranchPrune.desk_branches(not_a_repo).first
    end
  end

  def test_integration_cli_refuses_when_the_desk_read_fails
    assert_cli_refuses_when_git_fails("worktree list", /desks could not be read \(git worktree list: stub failure/)
  end

  def test_integration_cli_refuses_when_origin_branches_cannot_be_read
    assert_cli_refuses_when_git_fails("for-each-ref", /origin's branches could not be read/)
  end

  def test_integration_cli_refuses_when_the_merged_set_cannot_be_read
    assert_cli_refuses_when_git_fails("--merged", /the merged set could not be read/)
  end

  def test_integration_cli_reports_a_failed_delete_push_as_a_refusal
    with_remote do |work, _origin|
      before = remote_heads(work)
      out, status = run_cli(work, "--yes", git_fail: "push --porcelain")
      refute status.success?, out
      summary = BranchPrune.parse_summary(out)
      assert summary[:applied]
      assert_equal 0, summary[:count]
      assert_match(/the delete push failed \(git push exit 1/, summary[:refusal])
      assert_equal before, remote_heads(work)
    end
  end

  def assert_cli_refuses_when_git_fails(pattern, refusal)
    with_remote do |work, _origin|
      before = remote_heads(work)
      out, status = run_cli(work, "--yes", git_fail: pattern)
      assert_equal 1, status.exitstatus, out
      summary = BranchPrune.parse_summary(out)
      assert_equal 0, summary[:count]
      assert_empty summary[:sample]
      assert_match(refusal, summary[:refusal])
      assert_equal before, remote_heads(work), "a refused plan deletes nothing"
    end
  end

  def test_unit_cli_refuses_without_an_agent_token
    Dir.mktmpdir do |not_a_repo|
      out, status = run_cli(not_a_repo, token: "")
      refute status.success?
      assert_match(/refused: no agent GitHub token/, out)
    end
  end

  def test_integration_cli_dry_runs_then_deletes_only_merged_done_branches
    with_remote do |work, _origin|
      before = remote_heads(work)

      out, status = run_cli(work)
      assert status.success?, out
      summary = BranchPrune.parse_summary(out)
      refute summary[:applied]
      assert_equal %w[feat/archived feat/done], summary[:sample]
      assert_equal before, remote_heads(work), "a dry run deletes nothing"

      out, status = run_cli(work, "--yes")
      assert status.success?, out
      summary = BranchPrune.parse_summary(out)
      assert summary[:applied]
      assert_equal 2, summary[:count]
      assert_equal({ "not merged into main" => 1, "open PR" => 1, "bound to a desk" => 1,
                     "task not shipped or archived" => 1 }, summary[:skipped].transform_keys(&:to_s))

      after = remote_heads(work)
      assert_equal before - %w[feat/archived feat/done], after
      %w[main release accepted feat/open-pr feat/desk feat/unmerged feat/building].each do |kept|
        assert_includes after, kept
      end
    end
  end

  private

  def git(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", "-C", dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out
  end

  # `git rev-parse` prints the ref name and exits 128 on a missing ref, so the
  # status is checked here and a failure raises naming the ref, dir and exit code.
  def rev(dir, ref)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", "-C", dir, "rev-parse", "--verify", ref)
    unless status.success?
      raise "git rev-parse #{ref.inspect} failed in #{dir} (exit #{status.exitstatus}): #{err.strip}"
    end

    out.strip
  end

  def commit(dir, branch, msg)
    git(dir, "checkout", "-q", branch)
    File.write(File.join(dir, "#{msg}.txt"), msg)
    git(dir, "add", ".")
    git(dir, "commit", "-qm", msg)
    git(dir, "checkout", "-q", "main")
  end

  def remote_heads(work)
    git(work, "ls-remote", "--heads", "origin").lines.map { |l| l.split.last.delete_prefix("refs/heads/") }.sort
  end

  # origin: main, release and accepted at main's tip; feat/done, feat/archived,
  # feat/open-pr, feat/desk and feat/building merged into main; feat/unmerged one
  # commit ahead. A desk (worktree) holds feat/desk.
  def with_remote
    Dir.mktmpdir do |tmp|
      origin = File.join(tmp, "origin.git")
      work = File.join(tmp, "work")
      git(tmp, "init", "-q", "--bare", "-b", "main", origin)
      git(tmp, "clone", "-q", origin, work)
      git(work, "config", "user.email", "t@example.com")
      git(work, "config", "user.name", "t")
      git(work, "checkout", "-q", "-b", "main")
      File.write(File.join(work, "a.txt"), "a")
      git(work, "add", ".")
      git(work, "commit", "-qm", "root")
      %w[feat/done feat/archived feat/open-pr feat/desk feat/building feat/unmerged release accepted].each do |b|
        git(work, "branch", b)
      end
      commit(work, "feat/unmerged", "ahead")
      git(work, "push", "-q", "origin", "--all")
      git(work, "worktree", "add", "-q", File.join(tmp, "desk"), "feat/desk")
      git(work, "fetch", "-q", "origin")
      yield work, origin
    end
  end

  REAL_GIT = Open3.capture2("sh", "-c", "command -v git").first.strip

  # git_fail: a substring of the git arguments that makes the stub git fail; every
  # other call runs the real git.
  def run_cli(work, *args, gh_exit: 0, token: "stub-token", git_fail: nil)
    Dir.mktmpdir do |stubs|
      if git_fail
        write_stub(stubs, "git", <<~SH)
          #!/bin/sh
          case "$*" in
            *"#{git_fail}"*) echo "stub failure" >&2; exit 1 ;;
          esac
          exec "#{REAL_GIT}" "$@"
        SH
      end
      write_stub(stubs, "gh", <<~SH)
        #!/bin/sh
        [ "#{gh_exit}" = "0" ] || { echo "gh: HTTP 401" >&2; exit #{gh_exit}; }
        echo '[{"headRefName":"feat/open-pr"}]'
      SH
      write_stub(stubs, "task", <<~SH)
        #!/bin/sh
        case "$3" in
          shipped)  echo '[{"slug":"done"},{"slug":"open-pr"},{"slug":"desk"},{"slug":"unmerged"}]' ;;
          archived) echo '[{"slug":"other","branch":"feat/archived"}]' ;;
        esac
      SH
      write_stub(stubs, "gh-token", <<~SH)
        #!/bin/sh
        [ -n "#{token}" ] || { echo "no token" >&2; exit 1; }
        echo "#{token}"
      SH
      env = SessionEnv.neutralized(
        "PATH" => "#{stubs}:#{ENV.fetch('PATH')}",
        "PRUNE_BRANCHES_TASK_BIN" => File.join(stubs, "task"),
        "GH_AUTH_TOKEN_BIN" => File.join(stubs, "gh-token")
      )
      Open3.capture2e(env, BIN, "--repo", work, *args)
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end
end
