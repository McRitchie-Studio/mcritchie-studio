# frozen_string_literal: true

require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"
require "shellwords"
require "securerandom"

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

  # CLAUDE_PROJECTS_DIR is what the stamp resolves from when it is set, so this
  # is how a "the operator moved their projects directory" case is staged.
  def with_projects_dir(dir)
    had = ENV.key?("CLAUDE_PROJECTS_DIR")
    previous = ENV["CLAUDE_PROJECTS_DIR"]
    ENV["CLAUDE_PROJECTS_DIR"] = dir
    yield
  ensure
    had ? ENV["CLAUDE_PROJECTS_DIR"] = previous : ENV.delete("CLAUDE_PROJECTS_DIR")
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
  # WHAT THIS USED TO MISS (measured 2026-09-13, credential-snapshot-guards-overclaim).
  # It scanned `$SCRIPT_DIR` only, and the helper reaches op-meter.sh by the
  # INLINE form — `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/op-meter.sh`.
  # So deleting `bin/lib/op-meter.sh` from SHELL_FILES left all 13 tests GREEN
  # (exit 0) while the module's comment claimed this guard made that impossible.
  # Both forms are normalised to one marker below, so the scan sees every sibling
  # the helper resolves against its own directory however it spells it.
  SIBLING_DIR_IDIOM = /\$\(cd\s+"\$\(dirname\s+"\$\{BASH_SOURCE\[0\]\}"\)"\s*&&\s*pwd\)/

  # Written INTO the snapshot by the installer rather than copied from source, so
  # it is legitimately absent from the manifest. A separate test asserts the
  # installer really writes it — the exemption cannot hide a missing file.
  GENERATED_IN_SNAPSHOT = [CredentialHelperInstall::SNAPSHOT_ENV_RELATIVE].freeze

  test "every sibling bin/gh-app-git-credential reaches is in the manifest" do
    helper = File.read(Rails.root.join(CredentialHelperInstall::HELPER_RELATIVE))
    manifest = CredentialHelperInstall.manifest(SOURCE)

    normalised = helper.gsub(SIBLING_DIR_IDIOM, "$SCRIPT_DIR")

    # WHY `> raw` AND NOT `>= 4` (2026-09-13, the reviewer's mutation). The floor
    # was 4 and the RAW count is already 4 — the helper writes `$SCRIPT_DIR`
    # literally four times — so a dead SIBLING_DIR_IDIOM satisfied it and the
    # comment claiming this caught the normalisation going blind was false.
    # Comparing the two counts is what catches it: blind the idiom and they are
    # equal. (Coverage never depended on this line; the named-form assertions
    # below are what failed in that mutation.)
    raw = helper.scan("$SCRIPT_DIR").length
    normalised_count = normalised.scan("$SCRIPT_DIR").length

    assert_operator normalised_count, :>, raw,
                    "the $(cd $(dirname BASH_SOURCE) && pwd) normalisation matched nothing — the inline " \
                    "form is invisible to this scan again, which is exactly how op-meter.sh went unguarded"
    assert_operator normalised_count, :>=, 6,
                    "fewer sibling references than this helper has ever had — the scan itself has gone " \
                    "blind, and every assertion below would then grade an empty set"

    reached = normalised.scan(/\$SCRIPT_DIR\)?\/([A-Za-z0-9_.\/-]+)/).flatten.uniq
    refute_empty reached, "found no sibling references at all — this guard has stopped looking"

    # The two forms in the helper today. Named so a rewrite that drops one is a
    # decision someone makes here, not a silent loss of coverage.
    assert_includes reached, "gh-token", "the $SCRIPT_DIR form is no longer represented in this scan"
    assert_includes reached, "lib/op-meter.sh", "the inline BASH_SOURCE form is no longer represented in this scan"

    (reached - GENERATED_IN_SNAPSHOT.map { |rel| rel.delete_prefix("bin/") }).each do |rel|
      assert_includes manifest, "bin/#{rel}",
                      "the helper reaches bin/#{rel} from its own directory but the snapshot would not carry " \
                      "it; add it to SHELL_FILES or RUBY_ROOTS in bin/lib/credential_helper_install.rb"
    end
  end

  test "the sibling scan's generated-file exemption is a file the installer writes" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    snapshot = File.dirname(File.dirname(CredentialHelperInstall.helper_path(@root)))

    GENERATED_IN_SNAPSHOT.each do |rel|
      assert_path_exists File.join(snapshot, rel),
                         "#{rel} is exempted from the manifest scan because the installer writes it — and it " \
                         "did not. The exemption is then a hole: the helper sources a file nothing provides."
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

  # TIGHTENED AND RENAMED (credential-helper-claims-overclaim, 2026-09-14). The old
  # name — "and nothing in a working tree" — is no longer the property: the command
  # must NAME the in-tree path, as the value-PATTERN it replaces. What must never
  # be in a working tree is the VALUE git ends up holding, which is what this now
  # separates. It also runs the command, because the previous version asserted
  # about a string and the string was unrunnable on the machine it was written for.
  test "the printed command sets the stable path as the VALUE, and names a working tree only as the pattern it replaces" do
    command = CredentialHelperInstall.git_config_command(@root)
    value = command[/\.helper "([^"]+)"/, 1]
    pattern = command[/'([^']+)'\s*\z/, 1]

    assert_equal CredentialHelperInstall.helper_path(@root), value,
                 "the value git would hold is not the stable path"
    refute_includes value, "/projects/mcritchie-studio/bin/",
                    "the wiring still points into the hub primary's working tree"
    assert_includes command, 'credential."https://github.com".helper'
    assert_includes command, "--replace-all",
                     "a single-value set FAILS on a config that already holds two values — measured on a " \
                     "copy of the real ~/.gitconfig: 'cannot overwrite multiple values with a single value'"
    assert_equal CredentialHelperInstall::HELPER_VALUE_PATTERN, pattern,
                 "the value-pattern must target this helper's own lines. With no pattern at all --replace-all " \
                 "collapses EVERY value, dropping the empty reset that stops osxkeychain answering github.com; " \
                 "anchored on the in-tree path alone it appends a duplicate on every re-run."
    assert_match(/#{pattern}/, CredentialHelperInstall::IN_TREE_HELPER,
                 "the pattern no longer matches the in-tree line this install replaces")
    assert_match(/#{pattern}/, CredentialHelperInstall.helper_path(@root),
                 "the pattern no longer matches an ALREADY-installed helper, so a re-run appends instead of " \
                 "replacing — the duplication regression")
  end

  # The behavioural half: the command is run against a COPY of the two-value shape
  # a real ~/.gitconfig has. Nothing global is touched — `git config --file`.
  test "the printed command rewires a two-value config and keeps the empty reset" do
    config = File.join(@root, "gitconfig")
    File.write(config, <<~INI)
      [credential]
      \thelper = osxkeychain
      [credential "https://github.com"]
      \thelper =
      \thelper = #{CredentialHelperInstall::IN_TREE_HELPER}
    INI

    command = CredentialHelperInstall.git_config_command(@root)
                                     .sub("git config --global", "git config --file #{config}")
    assert system(command, out: File::NULL, err: File::NULL),
           "the printed wiring command FAILED on a config holding two values — the shape a real " \
           "~/.gitconfig has, and the reason the snapshot went unwired"

    values = `git config --file #{config} --get-all credential."https://github.com".helper`.split("\n", -1)[0..1]
    assert_equal ["", CredentialHelperInstall.helper_path(@root)], values,
                 "the empty reset must survive — it is what stops the generic [credential] osxkeychain " \
                 "helper answering github.com first — and the in-tree line must be the one replaced"
    assert_equal "osxkeychain", `git config --file #{config} credential.helper`.strip,
                 "the generic helper was touched; this command must only rewrite one URL's value"
  end

  # THE RE-RUN. `--replace-all <key> <value> <value-pattern>` replaces the lines
  # that MATCH and ADDS one when nothing does. So a pattern naming only the
  # in-tree path is correct exactly once: after the first run that line is gone,
  # every re-run matches nothing, and git appends another stable-path line. Three
  # runs, three helpers — measured on an isolated copy, never the real config.
  #
  # It is not cosmetic. `--check` cannot see it (`--get` returns only the LAST
  # value), and the runbook tells the operator to re-run after a rebuild, so the
  # duplicates accumulate silently under the one command that is supposed to be
  # the safe one.
  test "running the printed command three times leaves ONE helper, not three" do
    config = File.join(@root, "gitconfig")
    File.write(config, <<~INI)
      [credential]
      \thelper = osxkeychain
      [credential "https://github.com"]
      \thelper =
      \thelper = #{CredentialHelperInstall::IN_TREE_HELPER}
    INI

    command = CredentialHelperInstall.git_config_command(@root)
                                     .sub("git config --global", "git config --file #{config}")
    3.times { |i| assert system(command, out: File::NULL, err: File::NULL), "run #{i + 1} of the wiring command failed" }

    values = `git config --file #{config} --get-all credential."https://github.com".helper`.split("\n", -1)[0..-2]
    assert_equal ["", CredentialHelperInstall.helper_path(@root)], values,
                 "re-running the wiring command duplicated the helper: #{values.inspect}. git would then run " \
                 "the helper once per value, and --check cannot see it because --get reads only the last."
  end

  # REWORDED, not tightened (credential-snapshot-guards-overclaim, 2026-09-13).
  # The old name said the revert "restores the path it replaces", which is true
  # only on a machine whose credential.helper WAS that in-tree path. Where it was
  # unset, running the printed revert INSTALLS the helper by the path that
  # vanishes on checkout — the defect. Naming the true prior value is a change to
  # the CLI's contract (its --check arm already reads it) and belongs with the
  # source-control.md symptom-table gap Carl filed separately; what this guard
  # checks is only that the printed revert names the in-tree path, so that is
  # what it now claims.
  test "the revert command names the in-tree path this install replaces" do
    assert_includes CredentialHelperInstall.git_config_revert_command,
                    "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"
  end

  # The runbook and the code must not disagree about where the helper lives.
  # WHAT THIS USED TO MISS. It asserted only that the installer is MENTIONED, so
  # a doc carrying BOTH wirings passed — which docs/agents/modules/credentials.md
  # then did, with a `### Wiring (global, one time)` block naming the in-tree path
  # right above its Fresh Machine section (measured 2026-09-13). Two contradicting
  # authorities, and a machine rebuild would have followed the wrong one. The
  # refutation below is what makes the name of this test true, in both registered
  # docs.
  WIRING_DOCS = %w[
    docs/agents/modules/source-control.md
    docs/agents/modules/credentials.md
  ].freeze

  IN_TREE_HELPER = "projects/mcritchie-studio/bin/gh-app-git-credential"

  test "the wiring docs name the installed path and never the in-tree one" do
    WIRING_DOCS.each do |rel|
      doc = Rails.root.join(rel).read

      assert_includes doc, "bin/install-git-credential-helper",
                      "#{rel} does not name the installer, so it cannot be telling the operator to wire the " \
                      "snapshot path"

      offending = doc.lines.each_with_index.filter_map do |line, i|
        "#{rel}:#{i + 1}" if line.include?(IN_TREE_HELPER) && !line.lstrip.start_with?(">")
      end
      assert_empty offending,
                   "#{offending.join(', ')} still wires the helper by its in-tree path. That path vanishes " \
                   "for a window on every checkout — the defect this snapshot closes — and a doc that " \
                   "carries both wirings sends a fresh machine to the broken one."
    end
  end

  # The doc guard above checks the PATH the docs wire. This one checks the
  # COMMAND, which was the other half of the same disagreement: source-control.md
  # carried a single-value `git config … helper "<path>"` (measured exit 5 against
  # the real config's two-value shape — "cannot overwrite multiple values with a
  # single value"), while credentials.md described the --replace-all form. A doc
  # that names the right path with a command that cannot run is still a doc the
  # operator stops at. "All quote one source" has to be enforced to be true.
  test "the wiring docs print a command that runs, not a single-value set" do
    WIRING_DOCS.each do |rel|
      doc = Rails.root.join(rel).read

      assert_includes doc, "--replace-all",
                      "#{rel} wires credential.helper without --replace-all. That set FAILS (exit 5) on the " \
                      "two-value [credential \"https://github.com\"] a real ~/.gitconfig holds."
      assert_includes doc, CredentialHelperInstall::HELPER_VALUE_PATTERN,
                      "#{rel} omits the value-pattern #{CredentialHelperInstall::HELPER_VALUE_PATTERN.inspect}. " \
                      "A bare --replace-all collapses every value, dropping the empty reset that stops " \
                      "osxkeychain answering github.com."

      bare_set = doc.lines.each_with_index.filter_map do |line, i|
        next unless line.include?('credential."https://github.com".helper')
        next if line.include?("--replace-all") || line.lstrip.start_with?(">")

        "#{rel}:#{i + 1}"
      end
      assert_empty bare_set,
                   "#{bare_set.join(', ')} still carries a single-value set of credential.helper — the " \
                   "command that exits 5 on this machine and leaves the snapshot unwired."
    end
  end

  # ── --check reads the whole key, not the last line ──────────────────────────
  #
  # WHY THIS EXISTS. The duplication above went unseen because `--check` read the
  # wiring with `git config --get`, which returns only the LAST value. A config
  # holding three helpers and a config holding one printed the identical line and
  # the identical OK. So the check is now `--get-all`, and more than one value is
  # a FAIL naming the count.
  #
  # GIT_CONFIG_GLOBAL redirects `--global` at a file, so this runs the REAL CLI
  # against an isolated config. Nothing writes to ~/.gitconfig.
  def check_cli(config)
    Open3.capture2e(
      { "GIT_CONFIG_GLOBAL" => config },
      Rails.root.join("bin/install-git-credential-helper").to_s, "--check", "--root", @root
    ).first
  end

  def write_config(values)
    File.join(@root, "gitconfig").tap do |path|
      File.write(path, ["[credential \"https://github.com\"]", "\thelper =", *values.map { |v| "\thelper = #{v}" }].join("\n") + "\n")
    end
  end

  test "--check reports a duplicated helper instead of printing only the last value" do
    helper = CredentialHelperInstall.helper_path(@root)
    output = check_cli(write_config([helper, helper, helper]))

    assert_match(/FAIL.*3 helper values/, output,
                 "--check passed over a key holding three helper values. git runs the helper once per " \
                 "value; reading only the last is what made the re-run duplication invisible. Got:\n#{output}")
  end

  test "--check does not cry duplicate over a single wired helper" do
    output = check_cli(write_config([CredentialHelperInstall.helper_path(@root)]))

    refute_match(/helper values/, output,
                 "--check reported a duplicate on a correctly wired config:\n#{output}")
  end

  # ── two installs at once ────────────────────────────────────────────────────
  #
  # THE RACE (credential-snapshot-guards-overclaim, 2026-09-13). `install!` took
  # no lock, and its "already installed?" test sat outside one. Two installs of
  # the same NEW digest could both pass that test; A then renamed its staging
  # into place and pointed `current` at it, and B's `rm_rf(target)` deleted the
  # directory `current` was now pointing into — ENOENT to any concurrent
  # `git push`, which is the defect's own signature. Narrow (an install is an
  # explicit, rare command) but free to close.
  #
  # WHAT IS PROVEN HERE, exactly: that the critical section is serialised by a
  # real lock (a child blocks while this process holds it), and that a serialised
  # second install of the same digest rebuilds nothing. The original interleaving
  # cannot be REPLAYED without an injection point inside install!, so the
  # placement of the check is graded structurally instead — said plainly rather
  # than dressed up as a behavioural proof.

  def install_in_child(root)
    lib = Rails.root.join("bin/lib/credential_helper_install").to_s
    script = <<~RUBY
      require #{lib.inspect}
      CredentialHelperInstall.install!(source_root: #{SOURCE.inspect}, root: #{root.inspect})
      puts "installed"
    RUBY
    IO.popen([RbConfig.ruby, "-e", script], err: [:child, :out])
  end

  test "an install blocks while another holds the lock, and completes when it is released" do
    lock = File.open(File.join(@root, CredentialHelperInstall::LOCK_FILE), File::RDWR | File::CREAT, 0o600)
    lock.flock(File::LOCK_EX)
    child = install_in_child(@root)

    begin
      sleep 2
      assert_nil Process.wait2(child.pid, Process::WNOHANG),
                 "the install ran to completion while another process held the lock — the critical section " \
                 "is not serialised, so two installs of one digest can still delete each other's snapshot"
      refute_path_exists CredentialHelperInstall.current_link(@root),
                         "the blocked install repointed `current` before it held the lock"
    ensure
      lock.flock(File::LOCK_UN)
      lock.close
    end

    out = child.read
    Process.wait(child.pid) rescue nil
    assert_includes out, "installed", "the install did not complete once the lock was released: #{out}"
    assert_path_exists CredentialHelperInstall.helper_path(@root)
  end

  test "a second install of the same digest rebuilds nothing it could delete" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    snapshot = File.dirname(File.dirname(CredentialHelperInstall.helper_path(@root)))
    sentinel = File.join(snapshot, "sentinel-#{SecureRandom.hex(4)}")
    File.write(sentinel, "the directory `current` points into")

    child = install_in_child(@root)
    out = child.read
    Process.wait(child.pid) rescue nil

    assert_includes out, "installed", out
    assert_path_exists sentinel,
                       "the second install deleted and rebuilt the directory `current` already points into. " \
                       "A concurrent git push in that window gets ENOENT."
    assert_path_exists CredentialHelperInstall.helper_path(@root)
  end

  test "the already-installed test sits INSIDE the locked section" do
    # Structural, and only structural: replaying the interleaving would need an
    # injection point inside install!. What this catches is the check drifting
    # back out of the lock, which is the shape the race needed.
    source = File.read(Rails.root.join("bin/lib/credential_helper_install.rb"))
    body = source[/def install!.*?\n  end\n/m]
    refute_nil body, "install! could not be located — this guard would grade nothing"

    lock_at = body.index("with_install_lock(root) do")
    check_at = body.index("File.file?(File.join(target, MANIFEST_FILE))")
    swap_at = body.index("File.rename(staging, target)")
    point_at = body.index("point_current_at!(root, id)")

    [lock_at, check_at, swap_at, point_at].each_with_index do |at, i|
      refute_nil at, "step #{i} of install! is no longer recognisable; re-derive this guard"
    end
    assert_operator lock_at, :<, check_at,
                    "the already-installed test happens before the lock is taken — two installs of one " \
                    "digest can then both decide to build, and the loser deletes the winner's snapshot"
    assert_operator lock_at, :<, swap_at
    assert_operator lock_at, :<, point_at
  end

  # ── the installed snapshot's environment (what a snapshot cannot derive) ─────

  test "the install stamps the projects root the op-reads log belongs under" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    snapshot = File.dirname(File.dirname(CredentialHelperInstall.helper_path(@root)))
    stamp = File.read(File.join(snapshot, CredentialHelperInstall::SNAPSHOT_ENV_RELATIVE))

    expected = File.join(ProjectsRoot.default_projects_dir(SOURCE), ".agents", "op-reads.log")
    assert_includes stamp, expected,
                    "the snapshot does not carry the projects root, so OpMeter.log_path falls back to " \
                    "ProjectsRoot inside the snapshot and bin/op-reads loses every read bin/gh-token " \
                    "makes from the installed helper"
    refute_includes stamp, File.join(@root, "versions"),
                    "the stamp names a path inside the snapshot — that is the defect, written down"
  end

  # WHICH METER LOSES WHAT — pinned, because NINE sites said the wrong thing
  # (credential-helper-claims-overclaim). The claim that bin/op-reads sees nothing
  # at all from the installed helper was measured false: there are two meters and
  # only one of them drifts.
  #
  #   BASH  bin/lib/op-meter.sh   ${CLAUDE_PROJECTS_DIR:-$HOME/projects}  →  the REAL log, from a snapshot too
  #   RUBY  bin/lib/op_meter.rb   ProjectsRoot.default_projects_dir       →  inside the snapshot
  #
  # So the helper's own `op item get` was never lost; what was lost is every read
  # its Ruby child bin/gh-token makes, which is where the shared token session
  # spends its quota.
  #
  # WHY THE PATTERN LOOKS LIKE THIS. A first version scanned line by line with
  # `[^.\n]` between the words, and the reviewer measured it at 7 of 9 against
  # the pre-fix tree: it missed a PAST-tense form ("showed none") and every site
  # where a comment WRAPPED between the words, which is most of them. So the text
  # is flattened first — every newline becomes a space, and line numbers are kept
  # alongside — the verbs allow their tenses, and the gap between words allows the
  # comment markers a wrap inserts. The `[^.]` bound stays: it stops a match
  # running across a sentence boundary into an unrelated claim.
  #
  # And it is BUILT from parts rather than written out, so this guard can never
  # match itself. The earlier version needed two `# …-ok` exemption markers, and
  # the reviewer found both were dead — neither line could have matched anyway.
  WRAP_GAP = '[\s#*\/>]*'
  ZERO_READS_WORDING = Regexp.new(
    "op-reads[^.]{0,140}?(?:" \
    "zero#{WRAP_GAP}reads|" \
    "show(?:s|ed)?#{WRAP_GAP}(?:none|zero)|" \
    "report(?:s|ed)?#{WRAP_GAP}(?:zero|none)|" \
    "sees#{WRAP_GAP}(?:none|zero)" \
    ")",
    Regexp::IGNORECASE
  )

  CLAIM_FILES = %w[
    bin/gh-app-git-credential
    bin/install-git-credential-helper
    bin/lib/credential_helper_install.rb
    test/lib/credential_helper_install_test.rb
  ].freeze

  # Flatten newlines to spaces so a wrapped comment reads as one sentence, and
  # keep a line number for every character so an offender can be NAMED.
  def flattened_with_line_numbers(text)
    flat = +""
    lines = []
    line_no = 1
    text.each_char do |ch|
      flat << (ch == "\n" ? " " : ch)
      lines << line_no
      line_no += 1 if ch == "\n"
    end
    [flat, lines]
  end

  def zero_reads_offenders(text, label)
    flat, lines = flattened_with_line_numbers(text)
    offsets = []
    flat.scan(ZERO_READS_WORDING) { offsets << Regexp.last_match.begin(0) }
    offsets.map { |at| "#{label}:#{lines[at]}" }
  end

  test "the two meters still differ exactly as the comments say, and no file overstates what is lost" do
    bash = Rails.root.join("bin/lib/op-meter.sh").read
    ruby = Rails.root.join("bin/lib/op_meter.rb").read

    assert_match(/CLAUDE_PROJECTS_DIR:-\$HOME\/projects/, bash,
                 "the bash meter no longer falls back to $HOME/projects. If it derives the root from its own " \
                 "location now, the helper's OWN reads drift inside a snapshot too and every comment this " \
                 "guard protects has to be rewritten — starting with this one.")
    assert_match(/ProjectsRoot\.default_projects_dir/, ruby,
                 "the Ruby meter no longer resolves through ProjectsRoot — re-derive which half drifts")

    offenders = CLAIM_FILES.flat_map { |rel| zero_reads_offenders(Rails.root.join(rel).read, rel) }

    assert_empty offenders,
                 "these lines still say bin/op-reads sees nothing at all from the installed helper: " \
                 "#{offenders.join(', ')}. Measured false — the bash meter's reads land in the real log " \
                 "from a snapshot. Name what is actually lost: every read bin/gh-token makes."
  end

  # The guard's own floor: run it against the tree BEFORE this sweep and it must
  # find every site the sweep corrected. A pattern that catches some of them is
  # how the ninth survived eleven lines from one that was fixed.
  #
  # PINNED TO A SHA, never `origin/accepted` (zap, in review). The baseline must be
  # the tree that CARRIED the nine sites, and `origin/accepted` is the branch this
  # very sweep merges INTO — so the moment it lands, that ref holds the CORRECTED
  # files, `found` falls to 0, and this assertion reddens every later rails shard.
  # Measured both sides in review: 9 at the pin, 0 at the fix. The pin is an
  # ancestor of accepted forever and the rails job checks out `fetch-depth: 0`, so
  # CI always resolves it; an unresolvable one yields 0 and FAILS here rather than
  # passing, so the degradation stays closed.
  PRE_FIX_TREE = "ca4c5fda5fbad32f48a3b036e79c909aa0932a09"

  test "the pattern finds every site the pre-fix tree carried" do
    found = CLAIM_FILES.sum do |rel|
      text = `git -C #{Rails.root} show #{PRE_FIX_TREE}:#{rel} 2>/dev/null`
      next 0 if text.empty?

      zero_reads_offenders(text, rel).length
    end

    assert_operator found, :>=, 9,
                    "the pattern finds #{found} of the 9 sites #{PRE_FIX_TREE[0, 7]} carries. It is then a " \
                    "partial sweep wearing a guard's name — the exact shape this task exists to remove."
  end

  # NOTHING VERIFIED OR MAINTAINED THE STAMP (2026-09-13, the reviewer's measurement).
  # `stamp_snapshot_env!` sat inside install!'s "already built?" branch, so an
  # unchanged closure never re-stamped, and `stale?` never looked at the stamp at
  # all: deleting it left `--check` printing "installed … current" while the reads
  # bin/gh-token makes from the installed helper landed inside the snapshot and
  # `bin/op-reads` never saw them. A property nothing checks is not a property.

  test "a deleted stamp makes the install STALE rather than current" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    assert_not CredentialHelperInstall.stale?(source_root: SOURCE, root: @root), "control: a fresh install is current"

    File.delete(File.join(CredentialHelperInstall.current_link(@root), CredentialHelperInstall::SNAPSHOT_ENV_RELATIVE))

    assert_equal :missing, CredentialHelperInstall.stamp_state(source_root: SOURCE, root: @root)
    assert CredentialHelperInstall.stale?(source_root: SOURCE, root: @root),
           "a snapshot with no op-reads stamp reported as current. The operator then reads OK while " \
           "bin/op-reads is missing every read bin/gh-token makes from the installed helper — the exact " \
           "symptom, reported healthy."
  end

  test "a reinstall restores a deleted stamp, though the closure is unchanged" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    stamp = File.join(CredentialHelperInstall.current_link(@root), CredentialHelperInstall::SNAPSHOT_ENV_RELATIVE)
    before = File.read(stamp)
    File.delete(stamp)

    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)

    assert_path_exists stamp,
                       "the reinstall did not restore the stamp. The digest is unchanged, so install! skips " \
                       "the build — stamping has to happen outside that branch or `reinstall to fix it` is false."
    assert_equal before, File.read(stamp)
    assert_not CredentialHelperInstall.stale?(source_root: SOURCE, root: @root)
  end

  test "a stamp naming a different projects root is stale, and a reinstall moves it" do
    with_projects_dir("/tmp/projects-A") { CredentialHelperInstall.install!(source_root: SOURCE, root: @root) }
    assert_includes CredentialHelperInstall.stamped_projects_root(@root), "/tmp/projects-A"

    with_projects_dir("/tmp/projects-B-MOVED") do
      assert_equal :wrong_root, CredentialHelperInstall.stamp_state(source_root: SOURCE, root: @root)
      assert CredentialHelperInstall.stale?(source_root: SOURCE, root: @root),
             "the projects directory moved and the install still reported current"

      CredentialHelperInstall.install!(source_root: SOURCE, root: @root)

      assert_includes CredentialHelperInstall.stamped_projects_root(@root), "/tmp/projects-B-MOVED",
                      "reinstalling after a move did not rewrite the stamp — both the module comment and " \
                      "the generated file's own header promise that it does"
      assert_not CredentialHelperInstall.stale?(source_root: SOURCE, root: @root)
    end
  end

  # STRUCTURAL, and only structural: a torn read is a race this suite cannot
  # stage. What it pins is the shape that makes the race impossible — the stamp
  # lands in a directory `current` already points into, and `git push` reads the
  # helper without taking the install lock, so the write must be a rename(2).
  test "the stamp is written through a rename, never in place" do
    source = File.read(Rails.root.join("bin/lib/credential_helper_install.rb"))
    body = source[/def stamp_snapshot_env!.*?\n  end\n/m]

    refute_nil body, "stamp_snapshot_env! could not be located; this guard would grade nothing"
    assert_match(/File\.rename\(tmp, path\)/, body,
                 "the stamp is written in place. A reader in the window sees a truncated file, which on a " \
                 "credential path is a `set -u` failure mid-push.")
    assert_no_match(/File\.write\(path,/, body, "the final path is written directly rather than renamed onto")
  end

  test "the helper sources the stamp, and an exported value still wins" do
    CredentialHelperInstall.install!(source_root: SOURCE, root: @root)
    helper = CredentialHelperInstall.helper_path(@root)

    # Source the stamp exactly as the helper does — through the helper's own
    # directory — so this grades the wiring, not a restatement of it.
    sourced = `cd / && BASH_SOURCE_DIR=#{File.dirname(helper).shellescape} bash -c '
      . "$BASH_SOURCE_DIR/snapshot-env.sh"; printf "%s" "$MCR_OP_READS_LOG"'`
    assert_equal File.join(ProjectsRoot.default_projects_dir(SOURCE), ".agents", "op-reads.log"), sourced

    pinned = `cd / && MCR_OP_READS_LOG=/tmp/pinned.log BASH_SOURCE_DIR=#{File.dirname(helper).shellescape} bash -c '
      . "$BASH_SOURCE_DIR/snapshot-env.sh"; printf "%s" "$MCR_OP_READS_LOG"'`
    assert_equal "/tmp/pinned.log", pinned,
                 "the stamp overrode an exported value; a fixture that pins the log would stop recording"

    # NOT `assert_match(/snapshot-env\.sh/)`: that passes on the line that merely
    # COMPUTES the path. Measured 2026-09-13 — deleting the helper's sourcing line
    # left this suite green, which is the same overclaim this task exists to fix.
    # So look for a sourcing COMMAND that names the stamp, in either spelling.
    sourcing = File.read(helper).lines.grep(/(?:\A|[\s;&|])(?:\.|source)\s+"?\$\{?SNAPSHOT_ENV|(?:\A|[\s;&|])(?:\.|source)\s+"?[^"]*snapshot-env\.sh/)

    refute_empty sourcing,
                 "the helper computes the stamp's path but never sources it, so stamping it changes nothing " \
                 "and bin/op-reads still loses every read bin/gh-token makes from the installed helper"
  end
end
