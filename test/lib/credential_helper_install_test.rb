# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

require Rails.root.join("bin/lib/credential_helper_install").to_s

# [unit] CredentialHelperInstall — the snapshot that takes the git credential
# helper out of the moving hub primary.
#
# The behavioural proof (a tree actually moving under a running helper) lives in
# test/integration/credential_helper_survives_tree_move_test.rb. What is guarded
# HERE is the property that makes that fix trustworthy over time: the snapshot
# must be the helper's WHOLE closure, derived from the source rather than
# hand-listed, so a dependency added to bin/gh-token next month is copied
# without anyone remembering to edit a list.
class CredentialHelperInstallTest < ActiveSupport::TestCase
  SOURCE = Rails.root.to_s

  def setup
    @root = Dir.mktmpdir("credential-helper-install")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ── the manifest cannot rot ─────────────────────────────────────────────────

  test "the manifest is the helper's whole transitive require closure" do
    manifest = CredentialHelperInstall.manifest(SOURCE)

    # Re-derived here from the source rather than restated, so this fails if the
    # walker regresses to a hand-kept list.
    CredentialHelperInstall::RUBY_ROOTS.each do |root|
      closure = CredentialHelperInstall.require_closure(SOURCE, [root])
      missing = closure - manifest
      assert_empty missing,
                   "#{root} reaches #{missing.join(', ')}, which the snapshot would not carry — the " \
                   "installed helper would die on a missing require the first time it is used"
    end
  end

  test "every file the manifest names exists in the source tree" do
    missing = CredentialHelperInstall.manifest(SOURCE).reject { |rel| File.file?(File.join(SOURCE, rel)) }

    assert_empty missing, "the manifest names files that do not exist: #{missing.join(', ')}"
  end

  # The shell half is DECLARED (a bash script's siblings cannot be found by
  # walking `require_relative`), so it is the half that can rot. This re-reads
  # the helper's own source and fails if it reaches a sibling the snapshot would
  # not carry.
  test "every sibling bin/gh-app-git-credential reaches is in the manifest" do
    helper = File.read(Rails.root.join(CredentialHelperInstall::HELPER_RELATIVE))
    manifest = CredentialHelperInstall.manifest(SOURCE)

    reached = helper.scan(/\$SCRIPT_DIR\)?\/([A-Za-z0-9_.\/-]+)/).flatten.uniq
    refute_empty reached, "found no $SCRIPT_DIR references at all — this guard has stopped looking"

    reached.each do |rel|
      assert_includes manifest, "bin/#{rel}",
                      "the helper invokes $SCRIPT_DIR/#{rel} but the snapshot would not carry it; add it to " \
                      "SHELL_FILES or RUBY_ROOTS in bin/lib/credential_helper_install.rb"
    end
  end

  # ── the install itself ──────────────────────────────────────────────────────

  test "install produces an executable helper reachable through the stable path" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    helper = CredentialHelperInstall.helper_path(@root)

    assert_path_exists helper
    assert File.executable?(helper), "the snapshot's helper is not executable, so git cannot run it"
    assert File.symlink?(CredentialHelperInstall.current_link(@root)),
           "`current` must be a SYMLINK — a real directory cannot be repointed atomically"
  end

  test "the stable path lives outside every git working tree" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    helper = CredentialHelperInstall.helper_path(@root)

    refute helper.start_with?("#{SOURCE}#{File::SEPARATOR}"),
           "the installed helper is inside the repo it was copied from, which is the defect, not the fix"
    refute_path_exists File.join(File.realpath(CredentialHelperInstall.current_link(@root)), ".git"),
                       "the snapshot is itself a git working tree, so a checkout can still move it"
  end

  test "every require_relative inside the snapshot resolves to a file that is there" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    snapshot = File.realpath(CredentialHelperInstall.current_link(@root))

    unresolved = []
    Dir.glob("**/*", base: snapshot).each do |rel|
      path = File.join(snapshot, rel)
      next unless File.file?(path)
      next unless rel.end_with?(".rb") || File.read(path, 2) == "#!"

      File.foreach(path) do |line|
        match = line.match(/^\s*require_relative\s+["']([^"']+)["']/)
        next unless match

        target = File.expand_path(match[1], File.dirname(path))
        target = "#{target}.rb" unless File.extname(target) == ".rb"
        unresolved << "#{rel} -> #{match[1]}" unless File.file?(target)
      end
    end

    assert_empty unresolved,
                 "the snapshot carries requires that resolve to nothing: #{unresolved.join(', ')}"
  end

  test "install refuses a closure that does not resolve rather than shipping a partial snapshot" do
    partial = Dir.mktmpdir("partial-source", @root)
    CredentialHelperInstall::SHELL_FILES.each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(partial, rel)))
      FileUtils.cp(Rails.root.join(rel).to_s, File.join(partial, rel))
    end
    # RUBY_ROOTS are absent, so the closure names files that do not exist.

    error = assert_raises(ArgumentError) do
      CredentialHelperInstall.install!(source_root: partial, root: File.join(@root, "dest"))
    end

    assert_match(/Refusing to install a partial snapshot/, error.message)
    refute_path_exists CredentialHelperInstall.current_link(File.join(@root, "dest")),
                       "a refused install still left a `current` pointing somewhere"
  end

  # ── staleness ───────────────────────────────────────────────────────────────

  test "an install is not stale, and a changed source makes it stale" do
    scratch = File.join(@root, "src")
    FileUtils.mkdir_p(scratch)
    CredentialHelperInstall.manifest(SOURCE).each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(scratch, rel)))
      FileUtils.cp(Rails.root.join(rel).to_s, File.join(scratch, rel))
    end
    dest = File.join(@root, "dest")

    CredentialHelperInstall.install!(source_root: scratch, root: dest)
    refute CredentialHelperInstall.stale?(source_root: scratch, root: dest)

    File.write(File.join(scratch, CredentialHelperInstall::HELPER_RELATIVE), "\n# changed\n", mode: "a")

    assert CredentialHelperInstall.stale?(source_root: scratch, root: dest),
           "the source moved and the install did not notice — a stale credential helper is worse than a " \
           "missing one, because it fails silently and with last month's security posture"
  end

  test "nothing installed reads as stale rather than as current" do
    assert CredentialHelperInstall.stale?(source_root: SOURCE, root: File.join(@root, "empty"))
    assert_nil CredentialHelperInstall.installed_digest(File.join(@root, "empty"))
  end

  test "reinstalling an unchanged tree is idempotent and keeps the older snapshot" do
    first = CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    second = CredentialHelperInstall.install!(source_root: SOURCE, root: @root)

    assert_equal first, second
    assert_equal [first], Dir.children(CredentialHelperInstall.versions_dir(@root)).sort
  end

  # ── the wiring the operator runs ────────────────────────────────────────────

  test "the printed git config command names the stable path and nothing in a working tree" do
    command = CredentialHelperInstall.git_config_command(@root)

    assert_includes command, CredentialHelperInstall.helper_path(@root)
    assert_includes command, 'credential."https://github.com".helper'
    refute_includes command, "/projects/mcritchie-studio/bin/",
                    "the wiring still points into the hub primary's working tree"
  end

  test "the revert command restores the in-tree path it replaces" do
    assert_includes CredentialHelperInstall.git_config_revert_command,
                    "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"
  end

  # The runbook and the code must not disagree about where the helper lives.
  test "source-control.md documents the installed path, not the in-tree one" do
    doc = Rails.root.join("docs/agents/modules/source-control.md").read

    assert_includes doc, "bin/install-git-credential-helper",
                    "the source-control runbook still tells the operator to wire the in-tree helper by hand"
  end
end
