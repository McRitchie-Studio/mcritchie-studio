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
#      `<root>/versions/.agents/op-reads.log`, so `bin/op-reads` lost every read
#      the RUBY child `bin/gh-token` made from the installed helper — and that
#      report is the first thing gh-app-git-credential's own header tells you to
#      run when a 1Password quota spend needs explaining.
#
#      NOT "zero reads", which is what this said until 2026-09-14 and is what the
#      other six sites said with it. The helper's OWN `op` calls go through the
#      BASH meter, and op-meter.sh:72 falls back to
#      `${CLAUDE_PROJECTS_DIR:-$HOME/projects}` — $HOME, never ProjectsRoot — so
#      they landed in the real log from a snapshot all along. (`bin/gh-app-mint-token`
#      meters nothing at all, so it logs nowhere either way.) The blast radius was
#      the Ruby half; the fix below is unchanged and still worth having, because
#      the Ruby half is where the shared token session spends its quota. FIXED, not recorded: `install!` stamps the
#      resolved projects root into the snapshot as
#      `bin/snapshot-env.sh` (SNAPSHOT_ENV_RELATIVE), which the helper sources,
#      and both meters already honour `MCR_OP_READS_LOG` (bin/lib/op-meter.sh:70,
#      bin/lib/op_meter.rb:283). The stamp DEFAULT-assigns, so a caller's own
#      value still wins, and it is written per install — move the projects
#      directory and reinstall.
#   2. `TaskUsageSandbox.real_state_dir` names the snapshot root rather than
#      `<projects>/.agents`. That weakens the sandbox's rule 2 (a path pinned
#      back INSIDE the real store aborts) for a process running the SNAPSHOT
#      under TASK_USAGE_SANDBOX — which no test does, because tests run the repo
#      copy. Still recorded rather than worked around: the workaround (teaching
#      ProjectsRoot a pin) touches every consumer of a shared primitive to fix
#      nothing that is broken.
#
# THE TWO ARE COUPLED, and were written here as if they were not (corrected
# 2026-09-13). The stamp in (1) sets MCR_OP_READS_LOG on every snapshot
# invocation, and `op_meter_refused` (bin/lib/op-meter.sh:91) proceeds whenever
# that is set — so the BASH meter's rule 1 can no longer fire from a snapshot,
# and (2) is why rule 2 does not fire there either. What keeps a sandboxed run
# off the operator's real log is therefore not the guard but the fact that a
# sandboxed run executes the repo copy, never the install. Fix (2) and rule 2
# starts applying to the stamped path: re-read this note before doing so.
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
  #
  # The STAMP counts too. It is not part of the digest (it is generated, not
  # copied), so a digest comparison alone reports a snapshot with a deleted or
  # moved-root stamp as current — and that snapshot logs its 1Password reads
  # inside itself. A property nothing verifies is a property you do not have.
  def stale?(source_root:, root: DEFAULT_ROOT)
    return true if installed_digest(root) != digest(source_root)

    stamp_state(source_root: source_root, root: root) != :ok
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

    # EVERY INSTALL runs under the lock, INCLUDING its "already installed?" test.
    # Testing outside it is what let two installs of one digest both decide to
    # build, and the second one `rm_rf` the directory `current` was already
    # pointing into.
    #
    # NOT "everything that reads the version directories" — which is what this
    # said until 2026-09-14, and is contradicted twenty lines below: `git push`
    # resolves the helper through `current` WITHOUT taking this lock, which is
    # the whole reason `current` is repointed by rename(2). The residual that
    # leaves is narrow and the lock never closed it: point `current` at a version
    # directory whose manifest.json is missing, and the install below rm_rf's that
    # directory — a reader in that window sees the helper gone. It needs a
    # corrupted install to reach, and a reader that hits it gets the same ENOENT
    # a re-run repairs.
    with_install_lock(root) do
      unless File.file?(File.join(target, MANIFEST_FILE))
        staging = "#{target}.staging.#{Process.pid}"
        FileUtils.rm_rf(staging)
        copy_tree(source_root, staging, files)
        File.write(File.join(staging, MANIFEST_FILE),
                   "#{JSON.pretty_generate('digest' => id, 'files' => files, 'source_root' => source_root)}\n")
        FileUtils.rm_rf(target)
        FileUtils.mkdir_p(File.dirname(target))
        File.rename(staging, target)
      end

      # OUTSIDE the `unless`, deliberately. The stamp is not part of the digest,
      # so an unchanged closure skips the whole build above — and when the stamp
      # was written in there, a reinstall could not repair a deleted or stale one.
      # Measured before this moved: delete the stamp, reinstall, and it stayed
      # gone while `--check` reported the install current. Stamping the TARGET on
      # every install is what makes "reinstall fixes it" true.
      stamp_snapshot_env!(target, source_root)

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

  # The projects directory this source resolves — NOT a store path, which is the
  # point: everything public compares projects ROOTS, so the only place in this
  # file that ever builds `<projects>/.agents/...` is the private writer below
  # (LAYER 2a of test/lib/state_store_containment_test.rb: a raw store path must
  # not escape the file that built it, and a public method that reaches one is
  # how it escapes).
  def projects_root_for(source_root)
    env = ENV["CLAUDE_PROJECTS_DIR"].to_s.strip
    return File.expand_path(env) unless env.empty?

    ProjectsRoot.default_projects_dir(File.expand_path(source_root))
  end

  # The projects root the INSTALLED stamp records, or nil when there is no
  # readable stamp. Read off the stamp's own marker line.
  def stamped_projects_root(root = DEFAULT_ROOT)
    path = File.join(current_link(root), SNAPSHOT_ENV_RELATIVE)
    return nil unless File.file?(path)

    File.read(path)[/^# projects-root: (.+)$/, 1]
  rescue SystemCallError
    nil
  end

  # :ok, :missing (deleted, or installed before stamping existed) or :wrong_root
  # (the projects directory moved since the install). Anything but :ok is stale:
  # without the stamp the snapshot's RUBY reads (bin/gh-token) land INSIDE the
  # snapshot and `bin/op-reads` loses them — the symptom this file exists to
  # remove, which must never read as healthy. The helper's own bash-metered reads
  # are unaffected either way (op-meter.sh falls back to $HOME/projects).
  def stamp_state(source_root:, root: DEFAULT_ROOT)
    stamped = stamped_projects_root(root)
    return :missing if stamped.nil?

    stamped == projects_root_for(source_root) ? :ok : :wrong_root
  end

  # The projects root this snapshot was installed FROM, written where the helper
  # can source it. Default-assignment (`:=`), so an explicitly exported value —
  # a fixture's, or an operator's — still wins.
  #
  # WRITTEN THROUGH A RENAME, not in place. This lands in a directory `current`
  # already points into, and `git push` reads the helper without taking the
  # install lock — so a torn read is a `set -u` failure on the credential path.
  # rename(2) makes the swap atomic: a reader sees the old stamp or the new one.
  def stamp_snapshot_env!(dir, source_root)
    projects = projects_root_for(source_root)
    log = File.join(projects, ".agents", "op-reads.log")
    path = File.join(dir, SNAPSHOT_ENV_RELATIVE)
    tmp = "#{path}.tmp.#{Process.pid}"

    FileUtils.mkdir_p(File.dirname(path))
    File.write(tmp, <<~SH)
      # Generated by bin/install-git-credential-helper. Do not edit: every install
      # rewrites it, and `--check` reports a deleted or moved-root stamp as stale.
      # It is not part of the snapshot digest.
      # projects-root: #{projects}
      #
      # A snapshot's __dir__ is not the repo, so anything that derives the
      # projects root from its own location resolves INSIDE the snapshot. The
      # 1Password read-attribution log is the one that matters here: without this
      # stamp, the reads bin/gh-token makes from this snapshot land inside it and
      # bin/op-reads never sees them. (This script's own bash-metered reads are
      # unaffected: op-meter.sh falls back to $HOME/projects.)
      : "\${MCR_OP_READS_LOG:=#{log}}"
      export MCR_OP_READS_LOG
    SH
    File.chmod(0o644, tmp)
    File.rename(tmp, path)
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

  # The in-tree path this install replaces — the value a real ~/.gitconfig holds
  # today, and the one the wiring command below must target.
  IN_TREE_HELPER = "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"

  # The value-PATTERN both wiring commands below carry — every value that names
  # THIS helper, wherever it currently points: the in-tree path, an installed
  # snapshot path, or a stale snapshot from an earlier install. It is deliberately
  # not the in-tree path alone; see the note on re-runs below.
  HELPER_VALUE_PATTERN = "/gh-app-git-credential$"

  # The exact commands the operator runs. Kept here so the CLI, the tests and
  # docs/agents/modules/source-control.md all quote one source.
  #
  # --replace-all WITH A VALUE-PATTERN, and both halves are load-bearing (measured
  # 2026-09-14 against an isolated copy of the real ~/.gitconfig). That file holds
  # TWO values under [credential "https://github.com"]: an empty reset, then the
  # in-tree path. So:
  #   * a plain `git config … helper "<path>"` FAILS — "cannot overwrite multiple
  #     values with a single value"; the operator reads an error and stops, which
  #     is why the snapshot is still not wired on this machine;
  #   * a bare `--replace-all` SUCCEEDS and collapses both into one, dropping the
  #     empty reset that stops the generic [credential] helper = osxkeychain from
  #     answering github.com. osxkeychain would then answer first.
  # The value-pattern replaces only the lines naming this helper and leaves the
  # reset alone. On a config with one value or none, git adds the line instead —
  # measured, so the same command serves a fresh machine.
  #
  # WHY THE PATTERN IS NOT THE IN-TREE PATH ALONE. `--replace-all <key> <value>
  # <pattern>` replaces what MATCHES and ADDS when nothing does. Anchored on the
  # in-tree path it is correct exactly once: the first run consumes that line, and
  # every re-run matches nothing and APPENDS another helper. Three runs, three
  # helpers — measured 2026-09-14 on an isolated copy. git would then run the
  # helper once per value, and `--check` cannot see it because `--get` returns
  # only the LAST value. Matching any `…/gh-app-git-credential` makes the command
  # converge instead: it collapses whatever this helper's lines are to one.
  def git_config_command(root = DEFAULT_ROOT)
    %(git config --global --replace-all credential."https://github.com".helper ) +
      %("#{helper_path(root)}" '#{HELPER_VALUE_PATTERN}')
  end

  # ONE prior value, hard-coded: the in-tree path this install replaces. On a
  # machine where `credential.helper` was UNSET, running this revert INSTALLS the
  # defect rather than undoing anything. Left as-is deliberately — reading the
  # true prior value changes the CLI's contract, and bin/install-git-credential-helper
  # --check already reads it — but said out loud here so nobody reads the name as
  # a promise. Filed with the source-control.md symptom-table gap.
  # Carries the SAME value-pattern, for the same reason: a revert re-run must
  # converge on one in-tree line rather than append a second.
  def git_config_revert_command
    %(git config --global --replace-all credential."https://github.com".helper ) +
      %("#{IN_TREE_HELPER}" '#{HELPER_VALUE_PATTERN}')
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
