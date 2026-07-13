require "test_helper"
require "tmpdir"
require "open3"

# Regression guard for the ship-workspace index refresh in bin/release.rb's
# `deploy_app` (task refresh-ship-index-before-deploy).
#
# THE BUG: `deploy_app` (repo_script strategy) materializes and prepares the `_ship`
# workspace — `git reset --hard` writes files + index in the same clock-second (racy
# git), then `bundle check` + `bin/rails db:test:prepare` boot the app and bump
# tracked files' mtimes (a byte-identical Gemfile.lock rewrite; a rails-boot touch).
# That leaves the index's stat cache STALE for content-unchanged files. The repo's
# own deploy script (turf's bin/deploy) then gates on `git diff-index --quiet HEAD`
# with no refresh, reads the stat-stale tree as "uncommitted changes", and aborts a
# legitimate production ship. (rel-20260713-4dc6a7 was blocked three times by this.)
#
# THE FIX: `git update-index -q --refresh` on the workspace after prep, before the
# deploy. It re-hashes ONLY stat-dirty entries and clears the content-identical ones;
# a genuine content diff stays dirty and is reported — so the false positive is
# corrected without ever hiding real dirt.
class Release::ShipIndexRefreshTest < ActiveSupport::TestCase
  RELEASE_RB = Rails.root.join("bin", "release.rb")

  # --- behavioral: the git mechanism the fix relies on -------------------------
  test "a stat-stale but content-identical tree false-positives on raw diff-index; --refresh clears it" do
    Dir.mktmpdir do |dir|
      run!(dir, "git", "init", "-q")
      run!(dir, "git", "config", "user.email", "t@t")
      run!(dir, "git", "config", "user.name", "t")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n")
      run!(dir, "git", "add", "Gemfile.lock")
      run!(dir, "git", "commit", "-q", "-m", "init")

      assert quiet_clean?(dir), "sanity: a freshly-committed tree must read clean"

      # Rewrite with IDENTICAL bytes through a new inode + an old mtime — the exact
      # state the ship's reset+prep leaves a tracked file in (content unchanged, index
      # stat stale). No content change.
      restage_identical(dir, "Gemfile.lock", "GEM\n  remote\n")
      assert_equal "GEM\n  remote\n", File.read(File.join(dir, "Gemfile.lock"))

      refute quiet_clean?(dir),
             "the un-refreshed `git diff-index --quiet HEAD` must false-positive on a stat-stale, content-identical tree"

      system("git", "-C", dir, "update-index", "-q", "--refresh") # the fix
      assert quiet_clean?(dir),
             "after `git update-index -q --refresh` the content-identical tree must read clean"
    end
  end

  test "--refresh does NOT hide a genuine content change" do
    Dir.mktmpdir do |dir|
      run!(dir, "git", "init", "-q")
      run!(dir, "git", "config", "user.email", "t@t")
      run!(dir, "git", "config", "user.name", "t")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n")
      run!(dir, "git", "add", "Gemfile.lock")
      run!(dir, "git", "commit", "-q", "-m", "init")

      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n  REALLY CHANGED\n")
      system("git", "-C", dir, "update-index", "-q", "--refresh")
      refute quiet_clean?(dir),
             "a real content change must STILL read dirty after --refresh — the fix corrects staleness, it does not blank the check"
    end
  end

  # --- structural: deploy_app refreshes before the repo_script deploy ----------
  test "deploy_app refreshes the workspace index before invoking the repo's deploy script" do
    src = File.read(RELEASE_RB).lines
    refresh_line = src.index { |l| l =~ /git.*update-index.*--refresh/ }
    deploy_line  = src.index { |l| l =~ /sh\(command, \*args, chdir: workspace/ }

    assert refresh_line, "bin/release.rb must refresh the ship-workspace index (`git update-index --refresh`)"
    assert deploy_line, "bin/release.rb must still invoke the repo_script deploy via sh(command, *args, chdir: workspace, …)"
    assert refresh_line < deploy_line,
           "the index refresh must run BEFORE the repo_script deploy, or the stat-stale tree is not corrected"
    assert (deploy_line - refresh_line) <= 6,
           "the refresh must sit just before the deploy (inside deploy_app's ship-workspace block)"
  end

  private

  def quiet_clean?(dir)
    system("git", "-C", dir, "diff-index", "--quiet", "HEAD", "--")
  end

  def restage_identical(dir, name, content)
    path = File.join(dir, name)
    tmp = "#{path}.rewrite"
    File.write(tmp, content)
    File.rename(tmp, path)                # new inode → stat mismatch
    old = Time.utc(2000, 1, 1)
    File.utime(old, old, path)            # old mtime → guaranteed non-match, not racy
  end

  def run!(dir, *argv)
    out, status = Open3.capture2e(*argv, chdir: dir)
    assert status.success?, "command failed: #{argv.join(' ')}\n#{out}"
  end
end
