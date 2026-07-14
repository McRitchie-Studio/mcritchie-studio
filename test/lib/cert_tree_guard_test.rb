# frozen_string_literal: true

# Unit tests for bin/lib/cert_tree_guard.rb — the dirty-tree guard both G1 cert
# runners (bin/fast-check, bin/full-suite-check) consult before certifying an
# IMPLICITLY-resolved root. The cert fingerprint hashes the WORKING tree, so a cert
# taken with edits uncommitted stamps GREEN evidence over code the PR never gets
# (live 2026-07-14: 146 certified lines never reached PR #537). The guard refuses a
# dirty tree and names the offenders.
#
# The guard has TWO ways to fail and both are tested here:
#   * false NEGATIVE — a dirty tree certifies anyway (the bug we are fixing);
#   * false POSITIVE — a CLEAN tree is refused. The way to get this wrong is the
#     stat cache: a file rewritten with identical content has a fresh mtime, and the
#     cheap dirty reads (git diff-index --quiet) call that MODIFIED. On the cert
#     path a false refusal blocks every handoff, so the stale-mtime tree gets its
#     own tests below — including one that pins the index-refresh MECHANISM, not
#     just its happy-path outcome.
#
# The shelled end-to-end refusals live in test/lib/fast_check_test.rb and
# test/lib/full_suite_check_test.rb.
#   ruby -Itest test/lib/cert_tree_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../../bin/lib/cert_tree_guard"

class CertTreeGuardTest < Minitest::Test
  # A throwaway git repo with one committed file (tracked.rb) and a .gitignore,
  # yielded CLEAN as its realpath'd toplevel.
  def with_git_repo
    Dir.mktmpdir do |holder|
      real = File.realpath(holder)
      git(real, "init", "-q")
      git(real, "config", "user.email", "t@t.co")
      git(real, "config", "user.name", "T")
      File.write(File.join(real, "tracked.rb"), "class Tracked; end\n")
      File.write(File.join(real, ".gitignore"), "ignored/\n")
      git(real, "add", "-A")
      git(real, "commit", "-qm", "init")
      yield real
    end
  end

  def git(dir, *args)
    system("git", "-C", dir.to_s, *args, out: File::NULL, err: File::NULL)
  end

  def refusal(root)
    CertTreeGuard.refusal(command: "bin/fast-check", root: root)
  end

  # Re-stat every tracked file and rewrite the index's stat cache. This is what the
  # guard does; a test that wants to OBSERVE a stale index must not call it.
  def index_reads_dirty?(root)
    !system("git", "-C", root.to_s, "diff-index", "--quiet", "HEAD",
            out: File::NULL, err: File::NULL)
  end

  # ── [unit] the clean tree certifies ────────────────────────────────────────

  def test_clean_tree_does_not_refuse
    with_git_repo { |root| assert_nil refusal(root) }
  end

  def test_non_repo_is_unverifiable_not_dirty
    # "Can't read the tree" is NOT "dirty" — refusing here would block certs in any
    # non-git root. The runner's nil-fingerprint refusal already covers this case.
    Dir.mktmpdir { |dir| assert_nil refusal(dir) }
  end

  def test_ignored_files_are_not_dirt
    # The fingerprint honours .gitignore (git add -A), so the guard must too —
    # otherwise every build artifact would block a cert.
    with_git_repo do |root|
      FileUtils.mkdir_p(File.join(root, "ignored"))
      File.write(File.join(root, "ignored", "build.css"), "generated\n")
      assert_nil refusal(root), "a gitignored artifact is not uncommitted work"
    end
  end

  # ── [unit] the dirty tree is REFUSED, in each of its three shapes ───────────
  # All three are captured by the fingerprint (git add -A + write-tree), so all
  # three must refuse — an untracked NEW file is the easiest one to miss, and it is
  # exactly what "146 lines of finished work" looked like.

  def test_unstaged_edit_to_a_tracked_file_refuses_and_names_it
    with_git_repo do |root|
      File.write(File.join(root, "tracked.rb"), "class Tracked; def changed; end; end\n")
      message = refusal(root)
      refute_nil message, "an uncommitted edit must refuse the cert"
      assert_match(/DIRTY/, message)
      assert_match(/tracked\.rb/, message, "the refusal NAMES the offending file")
      assert_match(/commit/i, message, "the refusal states the fix")
      assert_match(/1 uncommitted change\b/, message, "singular, and counted")
    end
  end

  def test_staged_but_uncommitted_change_refuses
    with_git_repo do |root|
      File.write(File.join(root, "tracked.rb"), "class Tracked; def staged; end; end\n")
      git(root, "add", "-A")
      message = refusal(root)
      refute_nil message, "staged-but-uncommitted is still not on the PR"
      assert_match(/tracked\.rb/, message)
    end
  end

  def test_untracked_new_file_refuses
    with_git_repo do |root|
      File.write(File.join(root, "brand_new.rb"), "class BrandNew; end\n")
      message = refusal(root)
      refute_nil message, "an untracked file IS in the fingerprint — it must refuse"
      assert_match(/brand_new\.rb/, message)
    end
  end

  def test_many_offenders_are_counted_and_elided
    with_git_repo do |root|
      15.times { |i| File.write(File.join(root, "f#{i}.rb"), "x\n") }
      message = refusal(root)
      assert_match(/15 uncommitted changes/, message)
      assert_match(/… and 5 more/, message, "the list is capped at MAX_LISTED, the rest counted")
    end
  end

  # ── [unit] THE FALSE POSITIVE: a stat-stale index must still certify ────────
  #
  # A file rewritten with IDENTICAL content has a fresh mtime/ctime, so the index's
  # stat cache no longer matches the working tree. git calls that a "stale" index and
  # the cheap dirty reads report the file as MODIFIED. The guard exists to cure a
  # false dirty-abort — it must not BE one. It refreshes the index before reading it.

  # A repo whose index is stat-stale: content identical, mtime bumped. Nothing has
  # read the index since, so the staleness is still live.
  def with_stale_mtime_repo
    with_git_repo do |root|
      file = File.join(root, "tracked.rb")
      content = File.read(file)
      File.write(file, content)                                  # byte-identical rewrite
      FileUtils.touch(file, mtime: Time.now + (10 * 365 * 24 * 3600))
      yield root, file, content
    end
  end

  def test_stale_mtime_index_still_certifies
    with_stale_mtime_repo do |root, file, content|
      assert index_reads_dirty?(root),
             "fixture check: the index must actually BE stat-stale, else this proves nothing"
      assert_equal content, File.read(file), "fixture check: the CONTENT is unchanged"

      assert_nil refusal(root),
                 "a stat-stale index is a CLEAN tree — refusing it would block every handoff " \
                 "over a file nobody edited (the very false positive this guard exists to prevent)"
    end
  end

  def test_guard_leaves_the_index_refreshed
    # Pins the MECHANISM, not just the outcome. The outcome test above passes even
    # with a naive `git status --porcelain` and NO refresh, because status re-hashes
    # stat-mismatched entries itself — so it alone cannot prove we refreshed anything.
    # This asserts the observable side effect of the refresh: after the guard runs,
    # the on-disk index is no longer stale, so the cheap stat-cache reads
    # (`git diff-index --quiet HEAD` — what turf's bin/deploy uses, and what broke
    # the SHIP path) agree the tree is clean.
    #
    # GIT_OPTIONAL_LOCKS=0 is the discriminating vector: it forbids `git status` from
    # writing the refreshed index back, so a status-only implementation leaves the
    # index stale here and this test FAILS. `git update-index --refresh` takes a real
    # lock and writes. Guard against the next person swapping the read for a cheaper
    # one that false-positives.
    with_stale_mtime_repo do |root, _file, _content|
      assert index_reads_dirty?(root), "fixture check: index starts stale"

      with_env("GIT_OPTIONAL_LOCKS" => "0") { assert_nil refusal(root) }

      refute index_reads_dirty?(root),
             "the guard must REFRESH the index before reading it — the stat cache is " \
             "still stale, so this guard is only accidentally correct"
    end
  end

  def test_a_real_edit_under_a_stale_mtime_is_still_caught
    # The refresh must not go too far: it rewrites the stat cache only for entries
    # whose CONTENT still matches. A genuinely changed file with a bumped mtime is
    # real dirt and must still refuse — otherwise curing the false positive would
    # have opened a fail-GREEN hole.
    with_git_repo do |root|
      file = File.join(root, "tracked.rb")
      File.write(file, "class Tracked; def actually_changed; end; end\n")
      FileUtils.touch(file, mtime: Time.now + (10 * 365 * 24 * 3600))

      message = refusal(root)
      refute_nil message, "a REAL edit is dirt no matter what its mtime says"
      assert_match(/tracked\.rb/, message)
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved&.each { |k, v| ENV[k] = v }
  end
end
