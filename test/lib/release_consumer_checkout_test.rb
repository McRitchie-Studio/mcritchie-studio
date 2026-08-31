# frozen_string_literal: true

# Does `bin/release` find the hub when the hub is CHECKED OUT UNDER ANOTHER NAME?
#
# THE LAYOUT NO LOCAL RUN REPRODUCES. Every checkout on the operator's machine is a
# sibling at the projects root named exactly as the registry names it, so "the repo
# name" and "the directory name" are the same string and nothing distinguishes them.
# studio-engine's consumer-ci.yml checks each consumer out at
# `path: ${{ matrix.consumer }}`, and that matrix value is the UNDERSCORED label —
# `mcritchie_studio` for repo `mcritchie-studio`. There the two strings differ, and
# `File.join(projects_root, "mcritchie-studio")` pointed at nothing:
#
#   bin/lib/docs_archive.rb:217:in `git': git ls-files -- docs: fatal: cannot change
#     to '…/studio-engine/mcritchie-studio': No such file or directory
#     (DocsArchive::CommandFailed)
#
# read from a script that was itself running out of `…/studio-engine/mcritchie_studio`.
# Three archive tests in test/lib/release_cli_test.rb went red in `mcritchie_studio
# suite vs this engine`, the gem publish preflight failed with them, and a checkpoint
# release stopped. The hub's OWN CI is green on those same three tests, because in the
# projects-root layout both spellings are one directory — which is exactly why the
# defect shipped, and exactly why this file BUILDS the CI layout instead of trusting
# the local one.
#
# THE BREAK WAS NOT NEW — PR #984 REVEALED IT. bin/release.rb's `sweep_docs` call
# sites took `.first` of `[out, ok]` and dropped the exit code, so the docs step had
# been failing here all along with the failure swallowed. #984 taught the caller to
# honour the refusal, and the pre-existing breakage surfaced. Nothing in this file
# relaxes that: the beat is still expected to ABORT on a real refusal
# (test/lib/release_archive_docs_refusal_test.rb owns that half), and the repair is
# entirely in WHERE the sweep is pointed.
#
# WHY THE REAL bin/archive-docs AND A REAL GIT REPO. The bug was a directory the real
# script could not `cd` into. A stubbed sweep ignores `--repo=` and would have stayed
# green through the whole defect — the same trap that let the swallowed exit code live
# for months. So the fixture is a genuine git checkout carrying the hub's own
# bin/archive-docs, and the only things faked are the board and the artifact commit.
#
# Run directly:  ruby -Itest test/lib/release_consumer_checkout_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/repo_checkout"

class ReleaseConsumerCheckoutTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  # The checkout THIS test ships in — the source of the real sweep scripts below.
  HUB = File.expand_path("../..", __dir__)

  # Printed by the commit spy. `bin/release archive` reaching it proves the beat ran
  # THROUGH the docs sweep rather than aborting at it.
  COMPLETED = "SPY-ARTIFACT-COMMIT-REACHED"

  # The frozen snapshot the sweep should retire: dated, in audits/, cited by nothing.
  RETIRED_DOC = "docs/agents/audits/prelaunch-audit-2026-01-02.md"
  ARCHIVED_DOC = "docs/agents/archive/audits/prelaunch-audit-2026-01-02.md"

  # ---- the fixture ---------------------------------------------------------

  # Build <tmp>/workspace/<dir_name> as a REAL git checkout of a miniature hub, and
  # yield [workspace, hub]. `dir_name` is the whole experiment: `mcritchie_studio`
  # is the consumer lane's spelling, `mcritchie-studio` the projects-root one.
  #
  # The workspace holds ONLY that directory, so nothing but the resolution decides
  # whether the sweep finds a checkout — precisely the CI condition.
  def with_hub_checked_out_as(dir_name)
    Dir.mktmpdir("release-consumer-checkout") do |tmp|
      workspace = File.join(tmp, "workspace")
      hub = File.join(workspace, dir_name)
      FileUtils.mkdir_p(File.join(hub, "bin", "lib"))

      copy_real_sweep(hub)
      write_stub(hub, "agent-worktree", %(echo "reclaimed 0 worktree(s)"\nexit 0))
      write_stub(hub, "clean-artifacts", %(exit 0))
      plant_docs(hub)
      git_init(hub)

      yield workspace, hub
    end
  end

  # The hub's ACTUAL doc sweep, copied in — bin/archive-docs plus every lib it
  # requires. Copied rather than stubbed because `--repo=` is the variable under test.
  #
  # THE LIST IS DERIVED, NOT WRITTEN DOWN. It used to be the literal
  # `%w[docs_archive.rb ledger_guard.rb repo_root.rb]`, which was true only for as
  # long as bin/archive-docs required exactly those three. Adding a fourth
  # (lib/cli_arg_guard, the argument guard) broke both tests in this file with a
  # LoadError from inside the fixture — a failure about the FIXTURE's shape wearing
  # the costume of a failure about consumer checkouts, which is the most expensive
  # kind to read. Reading the requires out of the script keeps the copy honest
  # against a file that will keep growing.
  def copy_real_sweep(hub)
    script = File.join(HUB, "bin", "archive-docs")
    FileUtils.cp(script, File.join(hub, "bin", "archive-docs"))
    FileUtils.chmod(0o755, File.join(hub, "bin", "archive-docs"))

    libs = File.read(script).scan(/^require_relative\s+"lib\/([a-z0-9_]+)"/).flatten
    assert_operator libs.size, :>=, 3,
                    "expected to find bin/archive-docs' lib requires; got #{libs.inspect}"
    libs.each do |lib|
      FileUtils.cp(File.join(HUB, "bin", "lib", "#{lib}.rb"), File.join(hub, "bin", "lib", "#{lib}.rb"))
    end
  end

  def write_stub(hub, name, body)
    path = File.join(hub, "bin", name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  # A ledger with two RESOLVED rows (the older one rolls over) and one UNDATED row
  # (unresolved — always stays), plus one unreferenced frozen snapshot to retire. The
  # ledger rows deliberately cite worktrees, not docs: a row naming the snapshot would
  # PIN it as a live citation and the retirement half would never run.
  def plant_docs(hub)
    FileUtils.mkdir_p(File.join(hub, "docs", "agents", "maintenance"))
    FileUtils.mkdir_p(File.join(hub, "docs", "agents", "audits"))
    File.write(File.join(hub, "docs", "agents", "maintenance", "delete-later.md"), <<~MD)
      # Delete Later Ledger

      | Path | Type | Why it is a candidate | Safe-delete condition | Status |
      |------|------|-----------------------|-----------------------|--------|
      | `.worktrees/old-desk-a` | worktree | teardown left it behind | after the release ships | removed 2026-01-02 |
      | `.worktrees/old-desk-b` | worktree | teardown left it behind | after the release ships | removed 2026-02-03 |
      | `tmp/scratch-dir` | dir | regenerable scratch | reference only | pending approval |
    MD
    File.write(File.join(hub, RETIRED_DOC), "# Prelaunch Audit\n\nFrozen snapshot.\n")
  end

  def git_init(hub)
    run_git(hub, "init", "-q", "-b", "main")
    run_git(hub, "config", "user.email", "test@example.com")
    run_git(hub, "config", "user.name", "Release Consumer Test")
    run_git(hub, "add", "-A")
    run_git(hub, "commit", "-q", "-m", "fixture hub")
  end

  def run_git(hub, *args)
    out, status = Open3.capture2e("git", "-C", hub, *args)
    raise "git #{args.join(' ')} failed in #{hub}: #{out}" unless status.success?
  end

  # ---- driving the real CLI ------------------------------------------------

  # Spawn the REAL bin/release.rb, from INSIDE the fixture checkout (mirroring
  # consumer-ci's `working-directory: ${{ matrix.consumer }}`, which is what makes the
  # cwd-relative `bin/archive-docs` spawn resolve), with the projects root pinned at
  # the fixture workspace.
  #
  # PROJECTS_DIR is bin/release's own documented seam for a non-default checkout
  # layout, not a test-only backdoor: it supplies exactly the value consumer-ci's
  # layout makes `projects_root` compute — the directory the checkout sits in. What
  # the fix has to get right is the step AFTER that, choosing the directory NAME, and
  # that is the only thing left varying here.
  def run_archive(workspace, hub, argv: ["archive", "--yes", "--local"])
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{stubs}; archive)
    env = SessionEnv.neutralized(
      "PROJECTS_DIR" => workspace,
      "MCR_PRIMARY_LOCK_DIR" => File.join(workspace, ".locks")
    )
    out, err, status = Open3.capture3(env, "ruby", "-e", script, chdir: hub)
    ["#{out}\n#{err}", status]
  end

  # The board (Rails + a dyno) and the git write, faked. Everything between them —
  # repo_path, sweep_docs, the Open3 boundary, bin/archive-docs, git — is real.
  def stubs
    <<~RUBY
      def conductor(ruby, read_only: false)
        return { "archivable" => [], "kept" => [] } if ruby.include?("archivable_completed_slugs")
        { "archived" => [], "kept" => [], "count" => 0 }
      end
      def commit_artifact_to_release(*)
        puts(#{COMPLETED.inspect})
      end
    RUBY
  end

  # Assert one layout sweeps end-to-end. Shared so the two spellings are held to the
  # SAME bar — "it resolved" has to mean the same thing in both, or proving the new
  # one says nothing about the old one.
  def assert_sweeps_cleanly(dir_name)
    with_hub_checked_out_as(dir_name) do |workspace, hub|
      out, status = run_archive(workspace, hub)

      assert_predicate status, :success?,
                       "bin/release archive must complete with the hub checked out as " \
                       "#{dir_name.inspect} — a directory it cannot find aborts the beat " \
                       "at the docs sweep:\n#{out}"
      refute_includes out, "DocsArchive::CommandFailed",
                       "the sweep must never be handed a path it cannot cd into:\n#{out}"
      refute_includes out, "docs archive PREVIEW failed",
                       "the preview must not abort the beat:\n#{out}"

      # THE RESOLUTION ITSELF, read back from the child: bin/archive-docs echoes the
      # --repo it was given, so this asserts the exact directory the CLI chose rather
      # than inferring it from the run merely not blowing up.
      assert_includes out, "repo: #{hub}",
                      "the sweep must be pointed at the checkout that EXISTS:\n#{out}"

      # And it did real work there: the frozen snapshot moved, the older resolved
      # ledger row rolled, and the beat reached the artifact commit.
      assert_includes out, "Retired 1 frozen doc(s)", "the retirement half ran:\n#{out}"
      assert_includes out, "rolled 1 ledger row(s)", "the ledger half ran:\n#{out}"
      assert_includes out, COMPLETED, "the beat ran THROUGH the sweep:\n#{out}"
      assert_path_exists File.join(hub, ARCHIVED_DOC),
                         "the snapshot must actually be moved on disk, not merely reported"
      refute_path_exists File.join(hub, RETIRED_DOC),
                         "and moved OUT of the live tree"
    end
  end

  # ---- the regression ------------------------------------------------------

  # [integration] THE BUG, in the layout CI actually uses. Against the pre-fix CLI this
  # fails at the docs-archive PREVIEW: repo_path names `<workspace>/mcritchie-studio`,
  # nothing is there, and git raises DocsArchive::CommandFailed inside bin/archive-docs.
  def test_archive_sweeps_a_hub_checked_out_under_the_underscored_consumer_name
    assert_sweeps_cleanly("mcritchie_studio")
  end

  # [integration] THE CONTROL, and it is not optional: a "fix" that simply underscored
  # the name everywhere would pass the test above and break every ordinary run. The
  # projects-root spelling must sweep identically.
  def test_archive_still_sweeps_a_hub_checked_out_under_the_registry_name
    assert_sweeps_cleanly("mcritchie-studio")
  end

  # [unit] The same claim at bin/release's own seam, without the sweep: repo_path
  # RESOLVES a checkout, and resolves BOTH spellings to the directory that is there.
  # This is the assertion a revert of the fix reddens most directly.
  def test_repo_path_resolves_either_spelling_of_the_hub_checkout
    { "mcritchie_studio" => "the consumer lane's underscored checkout",
      "mcritchie-studio" => "the projects-root checkout" }.each do |dir_name, why|
      Dir.mktmpdir("repo-path-spelling") do |workspace|
        FileUtils.mkdir_p(File.join(workspace, dir_name))
        out = eval_helper(workspace, %(repo_path("mcritchie-studio")))

        assert_equal File.join(workspace, dir_name), out, "repo_path must find #{why}"
      end
    end
  end

  # [unit] An ABSENT sibling still resolves to the canonical name. This is the half
  # that keeps "the sibling is not here" distinguishable from "the sibling is here":
  # the caller gets today's path and today's error, so a missing checkout can never be
  # mistaken for a sweep that ran, and a real refusal can never be mistaken for a
  # missing checkout.
  def test_repo_path_keeps_the_registry_name_when_no_checkout_is_present
    Dir.mktmpdir("repo-path-absent") do |workspace|
      out = eval_helper(workspace, %(repo_path("turf-monster")))

      assert_equal File.join(workspace, "turf-monster"), out,
                   "an absent sibling must keep its canonical path — the miss has to stay legible"
    end
  end

  # Evaluate one bin/release helper in a clean subprocess with the projects root
  # pinned. (Mirrors release_cli_test's eval_helper; kept local because that file is
  # a frozen hotspot in config/test_health.yml.)
  def eval_helper(workspace, expr)
    env = SessionEnv.neutralized("PROJECTS_DIR" => workspace)
    out, err, status = Open3.capture3(env, "ruby", "-e", %(load #{BIN.inspect}; print(#{expr})))
    assert_predicate status, :success?, "bin/release must load standalone: #{err}"
    out
  end

  # ---- the pure rule -------------------------------------------------------

  # [unit] Canonical FIRST. When both spellings exist the registry name wins, so the
  # alternate can never shadow a real sibling on a machine that has both.
  def test_the_canonical_spelling_is_preferred_when_both_are_on_disk
    Dir.mktmpdir("repo-checkout-both") do |root|
      FileUtils.mkdir_p(File.join(root, "mcritchie-studio"))
      FileUtils.mkdir_p(File.join(root, "mcritchie_studio"))

      assert_equal File.join(root, "mcritchie-studio"),
                   RepoCheckout.resolve(root, "mcritchie-studio")
    end
  end

  # [unit] A FILE named like the checkout is not a checkout. The probe is
  # File.directory? on purpose — `mcritchie_studio.bak` shapes aside, a stray file
  # must not capture the resolution away from the canonical answer.
  def test_a_file_of_the_same_name_does_not_pass_as_a_checkout
    Dir.mktmpdir("repo-checkout-file") do |root|
      File.write(File.join(root, "mcritchie_studio"), "not a checkout")

      assert_equal File.join(root, "mcritchie-studio"),
                   RepoCheckout.resolve(root, "mcritchie-studio")
    end
  end

  # [unit] The spelling list: canonical first, both separators covered, no duplicates
  # for a name that carries neither.
  def test_spellings_are_canonical_first_and_deduplicated
    assert_equal %w[mcritchie-studio mcritchie_studio], RepoCheckout.spellings("mcritchie-studio")
    assert_equal %w[turf_monster turf-monster], RepoCheckout.spellings("turf_monster")
    assert_equal %w[rolio], RepoCheckout.spellings("rolio")
  end
end
