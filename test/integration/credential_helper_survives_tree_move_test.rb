# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

require Rails.root.join("bin/lib/credential_helper_install").to_s

# [integration] The git credential helper must survive the hub primary MOVING
# under it.
#
# THE DEFECT, measured four times on 2026-09-10 across three sessions.
# `~/.gitconfig` names the helper by a path inside the hub primary's WORKING
# TREE (`/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential`).
# `git checkout` does not rewrite a file in place — it unlinks the path and
# creates it afresh — so while that checkout runs the path does not exist, and a
# `git push` landing in the window dies with `No such file or directory`. It was
# measured with the helper's mtime matching the push to the second while the
# primary moved fbae68f0 → 50cfea07.
#
# HOW THIS TEST MOVES A TREE, and why it is honest. `test_the_in_tree_path...`
# checks out a commit in which the helper is ABSENT. That is the SAME physics as
# the measured window — the working tree's contents are whatever the checked-out
# commit says, and the config points into it — held open long enough to assert
# on deterministically instead of raced for. `test_the_installed_helper_survives
# _a_tree_that_is_actively_moving` then does the racy thing for real: it flips
# the sandbox repo between two commits whose helper content differs, in a
# background thread, while invoking the installed helper, and proves from the
# file's own inode that the tree really churned during the run.
#
# NOTHING HERE TOUCHES THE REAL HUB PRIMARY, a live desk, ~/.gitconfig, or the
# operator's token cache. The repo is a throwaway `git init` in a tmpdir, the
# install root is a tmpdir, CLAUDE_PROJECTS_DIR is pinned to a tmpdir, and every
# helper invocation runs with GH_APP_TOKEN_CMD pinned to a fake, so no
# 1Password read and no mint is possible.
class CredentialHelperSurvivesTreeMoveTest < ActiveSupport::TestCase
  def setup
    @sandbox = Dir.mktmpdir("credential-helper-tree-move")
    @repo = File.join(@sandbox, "hub")          # stands in for the hub primary
    @install_root = File.join(@sandbox, "install")
    @projects = File.join(@sandbox, "projects") # stands in for <projects>
    FileUtils.mkdir_p(File.join(@projects, ".agents"))

    seed_repo!
    @fake_token_cmd = write_fake_token_cmd
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # ── the defect, and the fix, side by side ───────────────────────────────────
  #
  # Both legs are asserted in ONE test on purpose: the first is the control that
  # proves the defect is real rather than folklore, and without the second the
  # first is just a complaint. Run against the code before this change there is
  # no installed path at all, so this test cannot pass.
  def test_the_in_tree_path_dies_while_the_tree_is_moved_and_the_installed_one_does_not
    digest = CredentialHelperInstall.install!(source_root: @repo, root: @install_root)
    installed = CredentialHelperInstall.helper_path(@install_root)
    in_tree = File.join(@repo, CredentialHelperInstall::HELPER_RELATIVE)

    assert_predicate File.stat(installed), :file?, "the install produced no helper at #{installed}"
    assert_equal digest, CredentialHelperInstall.installed_digest(@install_root)
    refute CredentialHelperInstall.stale?(source_root: @repo, root: @install_root),
           "a fresh install of an unmoved tree reads as stale"

    # MOVE THE TREE: land on the commit where the helper is not present. This is
    # a plain `git checkout`, the same operation that produced the four measured
    # failures — a deploy, a sweep, a release step, a session checking things in
    # and out all reach the working tree through it.
    git!(@repo, "checkout", "--quiet", "without-helper")

    refute_path_exists in_tree,
                       "the sandbox tree did not actually move — the control leg would pass vacuously"

    out, err, status = run_helper(in_tree)
    refute_predicate status, :success?,
                     "the IN-TREE helper answered while the tree was moved off it; that is the path " \
                     "~/.gitconfig names today, and this control must fail for the fix to mean anything " \
                     "(stdout=#{out.inspect} stderr=#{err.inspect})"

    out, err, status = run_helper(installed)
    assert_predicate status, :success?,
                     "the INSTALLED helper died while the hub tree moved — the snapshot is not immutable " \
                     "(stderr=#{err})"
    assert_match(/^password=ghs_pinned-by-the-test$/, out,
                 "the installed helper ran but did not answer git; a snapshot that cannot answer is not a fix")

    # The snapshot answered git from a tree that no longer contains the helper
    # at all — which is the whole claim — and it KNOWS it no longer matches the
    # checkout, so the staleness signal cannot be confused with the fix.
    assert CredentialHelperInstall.stale?(source_root: @repo, root: @install_root),
           "the source moved off the installed commit and `--check` would still report it current"
  end

  # The whole Ruby closure must LOAD from the snapshot, not merely be present.
  # `--status` reads the cache and prints; it mints nothing and reads no
  # 1Password. A missing or unresolvable `require_relative` inside the snapshot
  # fails here, at load, exactly as it would for the operator.
  def test_the_snapshots_ruby_closure_loads_from_outside_the_repo
    CredentialHelperInstall.install!(source_root: @repo, root: @install_root)
    gh_token = File.join(CredentialHelperInstall.current_link(@install_root), "bin/gh-token")

    git!(@repo, "checkout", "--quiet", "without-helper")

    out, err, status = Open3.capture3(sandbox_env, gh_token, "--status")

    assert_predicate status, :success?, "the snapshot's bin/gh-token could not load or run: #{err}"
    assert_match(/no cache yet/, out + err,
                 "bin/gh-token ran from the snapshot but did not reach its store; it resolved somewhere unexpected")
    assert_match(/#{Regexp.escape(@projects)}/, out + err,
                 "the snapshot resolved the token cache away from the pinned <projects> root — relocating the " \
                 "helper must NOT split the shared session (see bin/gh-token PROJECTS)")
  end

  # The racy version of the same thing: a tree genuinely churning under a
  # running helper.
  def test_the_installed_helper_survives_a_tree_that_is_actively_moving
    CredentialHelperInstall.install!(source_root: @repo, root: @install_root)
    installed = CredentialHelperInstall.helper_path(@install_root)
    in_tree = File.join(@repo, CredentialHelperInstall::HELPER_RELATIVE)

    stop = false
    inodes = []
    flips = 0
    mover = Thread.new do
      until stop
        git!(@repo, "checkout", "--quiet", flips.even? ? "rewritten-helper" : "main")
        flips += 1
      end
    rescue StandardError
      # A checkout losing a race with teardown must not mask the assertion below.
      nil
    end

    failures = []
    30.times do
      inodes << (File.stat(in_tree).ino rescue nil)
      _out, err, status = run_helper(installed)
      failures << err unless status.success?
    end
    stop = true
    mover.join(20)

    assert_empty failures,
                 "the installed helper failed #{failures.size}/30 times while the tree moved under it"
    assert_operator flips, :>, 1, "the mover never flipped the tree; the concurrency was not exercised"
    assert_operator inodes.compact.uniq.size, :>, 1,
                    "the in-tree helper kept ONE inode across #{flips} checkouts, so git never actually " \
                    "rewrote the file and this test proved nothing about a moving tree"
  end

  # An UPGRADE must not rebuild the very window this closes.
  #
  # THE PROPERTY, stated as the OS states it. The defect's signature is ENOENT —
  # `No such file or directory`. So what must be true of a re-install is that a
  # concurrent walker NEVER gets ENOENT through the stable path. rename(2)
  # delivers that; `rm` + `symlink` does not, and the control below shows why
  # without racing for it.
  #
  # Not asserted, and deliberately: rename can hand a walker that catches the
  # swap mid-flight a transient Errno::EINVAL (measured 88/5000 on APFS). That
  # is a path-resolution artifact rather than a missing file, it is bounded to
  # the instant of a deliberate re-install, and asserting a count on it would be
  # asserting a timing measurement.
  def test_repointing_current_never_makes_the_stable_path_vanish
    CredentialHelperInstall.install!(source_root: @repo, root: @install_root)
    stable = CredentialHelperInstall.helper_path(@install_root)
    link = CredentialHelperInstall.current_link(@install_root)

    # A second snapshot to swap between.
    File.write(File.join(@repo, "bin/lib/op-meter.sh"), "# altered\n", mode: "a")
    second = CredentialHelperInstall.install!(source_root: @repo, root: @install_root)
    first = Dir.children(CredentialHelperInstall.versions_dir(@install_root)).find { |d| d != second }
    refute_nil first, "expected two snapshots to swap between"

    # THE CONTROL, deterministic — no race. The stable path exists only while
    # `current` does, so any strategy that unlinks it first opens a real hole.
    FileUtils.rm_f(link)
    assert_raises(Errno::ENOENT, "with `current` unlinked the stable path must be GONE; if it survives " \
                                 "this control proves nothing about the swap below") { File.stat(stable) }
    CredentialHelperInstall.point_current_at!(@install_root, first)
    assert_path_exists stable, "the control did not restore `current`"

    stop = false
    swaps = 0
    swapper = Thread.new do
      until stop
        CredentialHelperInstall.point_current_at!(@install_root, swaps.even? ? first : second)
        swaps += 1
      end
    end

    vanished = 0
    2_000.times do
      File.stat(stable)
    rescue Errno::ENOENT
      vanished += 1
    rescue Errno::EINVAL
      nil # see the note above — transient resolution, not a missing file
    end
    stop = true
    swapper.join(20)

    assert_operator swaps, :>, 1, "the swapper never ran; the concurrency was not exercised"
    assert_equal 0, vanished,
                 "the stable helper path returned ENOENT #{vanished}/2000 times while `current` was " \
                 "repointed — that is the defect's own signature, so a re-install would reopen the " \
                 "window this closes. Repoint with rename(2), never rm + symlink."
  end

  private

  # A throwaway repo carrying the REAL helper closure, with three commits:
  #   main             — the closure as it ships
  #   rewritten-helper — the helper's content differs, so a checkout rewrites it
  #   without-helper   — the helper is gone, the widest form of the same window
  def seed_repo!
    files = CredentialHelperInstall.manifest(Rails.root.to_s)
    files.each do |rel|
      dst = File.join(@repo, rel)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(Rails.root.join(rel).to_s, dst)
      File.chmod(File.stat(Rails.root.join(rel).to_s).mode & 0o7777, dst)
    end

    git!(@repo, "init", "--quiet", "--initial-branch=main")
    git!(@repo, "add", "--all")
    commit!("v1 the closure as it ships")

    # Both variants branch OFF v1, so `main` keeps the helper and a checkout
    # between any two of the three is a real content change on disk.
    helper = File.join(@repo, CredentialHelperInstall::HELPER_RELATIVE)
    git!(@repo, "checkout", "--quiet", "-b", "rewritten-helper")
    File.write(helper, "#{File.read(helper)}\n# a later revision of the helper\n")
    git!(@repo, "add", "--all")
    commit!("v2 rewrites the helper")

    git!(@repo, "checkout", "--quiet", "main")
    git!(@repo, "checkout", "--quiet", "-b", "without-helper")
    git!(@repo, "rm", "--quiet", CredentialHelperInstall::HELPER_RELATIVE)
    commit!("v3 removes the helper")

    git!(@repo, "checkout", "--quiet", "main")
    assert_path_exists helper, "the seed left main without the helper; every install below would refuse"
  end

  def commit!(message)
    git!(@repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", "commit", "--quiet", "--message", message)
  end

  def git!(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # `get` with the shared-session leg pinned to a fake: the helper answers from
  # the "cache" and never reaches 1Password, the minter, or the network.
  #
  # A path that does not exist makes Open3 RAISE rather than return a failed
  # status — that is the defect itself, so it is caught and reported as the
  # failure it is instead of blowing up the test.
  def run_helper(path)
    Open3.capture3(sandbox_env.merge("GH_APP_TOKEN_CMD" => @fake_token_cmd), path, "get", stdin_data: "")
  rescue Errno::ENOENT => e
    ["", "#{e.class}: #{e.message}", FailedToLaunch.new]
  end

  # Stands in for a Process::Status when the helper could not be launched at all.
  class FailedToLaunch
    def success? = false
    def to_s = "not launched"
  end

  def sandbox_env
    {
      "CLAUDE_PROJECTS_DIR" => @projects,
      "PROJECTS_DIR" => @projects,
      "MCR_OP_READS_LOG" => File.join(@sandbox, "op-reads.log"),
      "GH_APP_ITEM" => "github.mcritchie-agent"
    }
  end

  def write_fake_token_cmd
    path = File.join(@sandbox, "fake-gh-token")
    File.write(path, "#!/bin/sh\necho ghs_pinned-by-the-test\n")
    File.chmod(0o755, path)
    path
  end
end
