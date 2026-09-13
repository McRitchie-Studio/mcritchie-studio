# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "projects_root"

# CredentialHelperInstall — pin the git credential helper OUTSIDE every working
# tree, so a `git push` cannot lose it while a checkout moves under it.
#
# THE DEFECT (measured four times on 2026-09-10, across three sessions).
# `~/.gitconfig` names the helper by a path INSIDE the hub primary's working
# tree:
#
#   credential."https://github.com".helper =
#     /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential
#
# `git checkout` does not rewrite a file in place. For every path whose content
# differs between the two commits it calls unlink(2) and then creates the file
# afresh, so there is a window in which the path DOES NOT EXIST. Any git
# operation that asks for credentials inside that window dies with
# `gh-app-git-credential: No such file or directory`. It was measured with the
# helper's mtime matching the push to the second while the primary moved
# fbae68f0 → 50cfea07. The same physics kills a checkout that lands on a commit
# where the file is absent entirely, for as long as that commit is checked out.
#
# THE FIX. Install a COHERENT SNAPSHOT of the helper and everything it reaches
# into a content-addressed directory that no checkout ever touches, and point
# git at a stable symlink into it:
#
#   <root>/versions/<digest>/bin/gh-app-git-credential   the snapshot
#   <root>/current -> versions/<digest>                  the stable path
#
# Two properties carry the guarantee:
#
#   COHERENT — the snapshot is the helper's whole transitive closure, DERIVED
#     from the source on every install (see `manifest`), never a hand-kept list
#     that rots. A partial copy would fail later and further from the cause than
#     the defect it replaces, so `install!` REFUSES rather than install one.
#
#   NEVER ABSENT — `current` is repointed by rename(2) over the existing
#     symlink, which is atomic, so the stable path resolves to the old snapshot
#     or the new one and an upgrade cannot reproduce the very window this exists
#     to close. Measured on APFS 2026-09-13, hammering one path while a thread
#     swapped `current`: rename gave 0 ENOENT in 5000 stats across 348 swaps,
#     while `rm` + `symlink` — the obvious way to write this — gave 2899. ENOENT
#     is the defect's exact signature, so that difference IS the fix.
#     (rename does surface a transient Errno::EINVAL to a walker that catches
#     the swap mid-flight — 88/5000 above. That is a path-resolution artifact,
#     not a missing file, and it is bounded to the instant of a deliberate
#     re-install rather than to every checkout of the hub primary.)
#     Old version directories are KEPT for the same reason: a helper process
#     already running out of one keeps its files.
#
# WHAT SURVIVES RELOCATION, AND WHY THIS IS SAFE. The one thing that could have
# broken is the SHARED SESSION: bin/gh-token holds the hour-long installation
# token in `<projects>/.agents/github-tokens.json`, and a warm git operation
# costs ZERO 1Password reads because of it. Splitting that cache would send
# every git operation back down the mint path — three 1Password reads each —
# which is the failure the helper's own header records as eighteen hours of
# downtime when the account-wide daily quota ran out. It survives: bin/gh-token
# resolves `PROJECTS` from CLAUDE_PROJECTS_DIR, else `~/projects` — a HOME-based
# default, not a `__dir__`-based one — so a snapshot at any path still reads and
# writes the operator's one shared cache. Verified 2026-09-13 (bin/gh-token:130).
#
# WHAT DOES MOVE: `ProjectsRoot::REPO_ROOT` is `__dir__`-based, so inside a
# snapshot it names the snapshot, and the closure has TWO consumers of it — not
# one, as this header claimed until 2026-09-13.
#
#   1. `OpMeter.log_path` (bin/lib/op_meter.rb) falls back to
#      `ProjectsRoot.default_projects_dir` when CLAUDE_PROJECTS_DIR is unset,
#      which an ordinary shell is. In a snapshot that resolved to
#      `<root>/versions/.agents/op-reads.log`, so `bin/op-reads` showed ZERO
#      reads from the installed helper — and that report is the first thing
#      gh-app-git-credential's own header tells you to run when a 1Password
#      quota spend needs explaining. FIXED, not recorded: `install!` stamps the
#      resolved projects root into the snapshot as
#      `bin/snapshot-env.sh` (SNAPSHOT_ENV_RELATIVE), which the helper sources,
#      and both meters already honour `MCR_OP_READS_LOG` (bin/lib/op-meter.sh:70,
#      bin/lib/op_meter.rb:283). The stamp DEFAULT-assigns, so a caller's own
#      value still wins, and it is written per install — move the projects
#      directory and reinstall.
#   2. `TaskUsageSandbox.real_state_dir` names the snapshot root rather than
#      `<projects>/.agents`. That only weakens the sandbox's rule 2 (OUTSIDE),
#      and only for a process running the SNAPSHOT under TASK_USAGE_SANDBOX —
#      which no test does, because tests run the repo copy. Rule 1 (PINNED) is
#      unaffected. Still recorded rather than worked around: the workaround
#      (teaching ProjectsRoot a pin) touches every consumer of a shared
#      primitive to fix nothing that is broken.
#
# This module does NOT touch ~/.gitconfig. Wiring a global config file is
# operator-visible and reversible by hand, so the CLI PRINTS the exact commands
# (`git_config_command` / `git_config_revert_command`) and the operator runs
# them. See bin/install-git-credential-helper.
module CredentialHelperInstall
  # The helper git actually invokes, plus the shell library it sources. Neither
  # is reachable by walking `require_relative`, so they are declared — and
  # `test/lib/credential_helper_install_test.rb` re-derives FROM THE SOURCE
  # every sibling the helper resolves against its OWN directory, in both forms
  # it writes them: `$SCRIPT_DIR/x` and the inline
  # `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/x`. It fails if one is
  # missing here, so this list cannot rot into a lie quietly.
  #
  # THE SECOND FORM IS WHY THAT SENTENCE IS NOW TRUE. Until 2026-09-13 the guard
  # scanned `$SCRIPT_DIR` only, and bin/gh-app-git-credential reaches
  # op-meter.sh by the inline form — so deleting `bin/lib/op-meter.sh` from this
  # list left all 13 tests GREEN (measured). The claim was right about intent and
  # wrong about coverage.
  SHELL_FILES = %w[
    bin/gh-app-git-credential
    bin/lib/op-meter.sh
  ].freeze

  # The Ruby programs the helper shells out to (`$SCRIPT_DIR/gh-token`,
  # `$SCRIPT_DIR/gh-app-mint-token`). Their `require_relative` closure is walked,
  # not listed.
  RUBY_ROOTS = %w[
    bin/gh-token
    bin/gh-app-mint-token
  ].freeze

  DEFAULT_ROOT = File.join(Dir.home, ".mcritchie", "git-credential")

  # The helper's own relative path inside a snapshot.
  HELPER_RELATIVE = "bin/gh-app-git-credential"

  MANIFEST_FILE = "manifest.json"

  # Written INTO each snapshot by `install!` (never copied from source): the
  # environment a snapshot cannot derive from its own `__dir__`. The helper
  # sources it if present. See "WHAT DOES MOVE" above.
  SNAPSHOT_ENV_RELATIVE = "bin/snapshot-env.sh"

  # Serialises the whole check-stage-swap critical section. Two installs of the
  # same NEW digest could both pass the "already installed?" test, and the
  # loser's `rm_rf(target)` then deleted the directory `current` had just been
  # pointed into — ENOENT to any concurrent `git push`, the defect's own
  # signature, in a few-ms window. Rare (an explicit operator command) but free
  # to close.
  LOCK_FILE = ".install.lock"

  module_function

  # Every file the snapshot must carry, repo-relative and sorted. DERIVED: the
  # Ruby half is the transitive `require_relative` closure of RUBY_ROOTS, so a
  # dependency added to bin/gh-token tomorrow is picked up without editing this
  # file.
  def manifest(source_root)
    (SHELL_FILES.dup + require_closure(source_root, RUBY_ROOTS)).uniq.sort
  end

  # The transitive `require_relative` closure of +roots+, repo-relative. A
  # target that does not exist is returned as-is so the caller can refuse on it
  # rather than silently shipping a snapshot that is missing a file.
  def require_closure(source_root, roots)
    seen = []
    queue = roots.dup

    until queue.empty?
      rel = queue.shift
      next if seen.include?(rel)

      seen << rel
      path = File.join(source_root, rel)
      next unless File.file?(path)

      File.foreach(path) do |line|
        match = line.match(/^\s*require_relative\s+["']([^"']+)["']/)
        next unless match

        target = File.expand_path(match[1], File.dirname(path))
        target = "#{target}.rb" unless File.extname(target) == ".rb"
        queue << relative_to(target, source_root)
      end
    end

    seen
  end

  # Content address for a source tree's manifest: the digest changes when any
  # file in the closure changes, and when the closure itself gains or loses a
  # file. Twelve hex characters — enough to name a directory without being a
  # cryptographic claim.
  def digest(source_root)
    entries = manifest(source_root).map do |rel|
      path = File.join(source_root, rel)
      content = File.file?(path) ? File.binread(path) : ""
      "#{rel}\0#{Digest::SHA256.hexdigest(content)}"
    end
    Digest::SHA256.hexdigest(entries.join("\n"))[0, 12]
  end

  def versions_dir(root) = File.join(root, "versions")
  def current_link(root) = File.join(root, "current")
  def version_dir(root, digest) = File.join(versions_dir(root), digest)

  # The stable path git is pointed at. It goes through `current`, never through
  # a version directory, so an upgrade does not require rewriting ~/.gitconfig.
  def helper_path(root = DEFAULT_ROOT) = File.join(current_link(root), HELPER_RELATIVE)

  # The digest `current` resolves to, or nil when nothing is installed.
  def installed_digest(root = DEFAULT_ROOT)
    link = current_link(root)
    return nil unless File.symlink?(link) || File.directory?(link)

    manifest_path = File.join(link, MANIFEST_FILE)
    return nil unless File.file?(manifest_path)

    JSON.parse(File.read(manifest_path))["digest"]
  rescue JSON::ParserError
    nil
  end

  # Does the installed snapshot differ from the source tree? A missing install
  # counts as stale — there is nothing to answer with.
  def stale?(source_root:, root: DEFAULT_ROOT)
    installed_digest(root) != digest(source_root)
  end

  # Install the snapshot and repoint `current`. Returns the digest.
  #
  # Idempotent: re-installing an unchanged tree rewrites nothing and returns the
  # same digest. Refuses, loudly, on a closure that does not resolve — see
  # COHERENT above.
  def install!(source_root:, root: DEFAULT_ROOT)
    files = manifest(source_root)
    missing = files.reject { |rel| File.file?(File.join(source_root, rel)) }
    unless missing.empty?
      raise ArgumentError,
            "credential-helper install: #{missing.size} file(s) in the helper's closure do not exist " \
            "under #{source_root}: #{missing.join(', ')}. Refusing to install a partial snapshot — " \
            "a missing dependency would fail later and further from the cause than the defect this closes."
    end

    id = digest(source_root)
    target = version_dir(root, id)

    # EVERYTHING that reads or writes the version directories happens under the
    # lock, INCLUDING the "already installed?" test. Testing outside it is what
    # let two installs of one digest both decide to build, and the second one
    # `rm_rf` the directory `current` was already pointing into.
    with_install_lock(root) do
      unless File.file?(File.join(target, MANIFEST_FILE))
        staging = "#{target}.staging.#{Process.pid}"
        FileUtils.rm_rf(staging)
        copy_tree(source_root, staging, files)
        stamp_snapshot_env!(staging, source_root)
        File.write(File.join(staging, MANIFEST_FILE),
                   "#{JSON.pretty_generate('digest' => id, 'files' => files, 'source_root' => source_root)}\n")
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(File.dirname(target))
        File.rename(staging, target)
      end

      point_current_at!(root, id)
    end
    id
  end

  # Hold an exclusive flock on `<root>/.install.lock` for the block. The lock
  # file is never deleted: unlinking it would let a later install take a lock on
  # a file nobody else can see any more.
  def with_install_lock(root)
    FileUtils.mkdir_p(root)
    File.open(File.join(root, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      begin
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  # The projects root this snapshot was installed FROM, written where the helper
  # can source it. Default-assignment (`:=`), so an explicitly exported value —
  # a fixture's, or an operator's — still wins.
  def stamp_snapshot_env!(staging, source_root)
    projects = ENV["CLAUDE_PROJECTS_DIR"].to_s.strip
    projects = ProjectsRoot.default_projects_dir(File.expand_path(source_root)) if projects.empty?
    log = File.join(File.expand_path(projects), ".agents", "op-reads.log")
    path = File.join(staging, SNAPSHOT_ENV_RELATIVE)

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~SH)
      # Generated by bin/install-git-credential-helper. Do not edit: reinstalling
      # rewrites it, and it is not part of the snapshot digest.
      #
      # A snapshot's __dir__ is not the repo, so anything that derives the
      # projects root from its own location resolves INSIDE the snapshot. The
      # 1Password read-attribution log is the one that matters here: without
      # this stamp, `bin/op-reads` shows zero reads from the installed helper.
      : "\${MCR_OP_READS_LOG:=#{log}}"
      export MCR_OP_READS_LOG
    SH
    File.chmod(0o644, path)
    path
  end
  private_class_method :stamp_snapshot_env!

  # Repoint `current` ATOMICALLY. rename(2) over an existing symlink replaces it
  # in one step, so a concurrent `git push` resolves the old snapshot or the new
  # one — never a hole. Using `rm` + `symlink` here would rebuild the exact
  # window this module exists to close: measured, it returns ENOENT — the
  # defect's own signature — to 58% of concurrent reads. See NEVER ABSENT above.
  def point_current_at!(root, id)
    link = current_link(root)
    tmp = "#{link}.tmp.#{Process.pid}"
    FileUtils.mkdir_p(root)
    FileUtils.rm_f(tmp)
    File.symlink(File.join("versions", id), tmp)
    File.rename(tmp, link)
  end

  # The exact commands the operator runs. Kept here so the CLI, the tests and
  # docs/agents/modules/source-control.md all quote one source.
  def git_config_command(root = DEFAULT_ROOT)
    %(git config --global credential."https://github.com".helper "#{helper_path(root)}")
  end

  # ONE prior value, hard-coded: the in-tree path this install replaces. On a
  # machine where `credential.helper` was UNSET, running this revert INSTALLS the
  # defect rather than undoing anything. Left as-is deliberately — reading the
  # true prior value changes the CLI's contract, and bin/install-git-credential-helper
  # --check already reads it — but said out loud here so nobody reads the name as
  # a promise. Filed with the source-control.md symptom-table gap.
  def git_config_revert_command
    %(git config --global credential."https://github.com".helper ) +
      %("/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential")
  end

  def copy_tree(source_root, dest, files)
    files.each do |rel|
      src = File.join(source_root, rel)
      dst = File.join(dest, rel)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
      File.chmod(File.stat(src).mode & 0o7777, dst)
    end
  end

  def relative_to(path, root)
    expanded_root = File.expand_path(root)
    expanded = File.expand_path(path)
    return expanded unless expanded.start_with?("#{expanded_root}#{File::SEPARATOR}")

    expanded[(expanded_root.length + 1)..]
  end
end
