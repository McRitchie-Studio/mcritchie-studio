# frozen_string_literal: true

# Does `bin/release` find the hub when CHECKED OUT UNDER ANOTHER NAME? studio-engine's
# consumer-ci.yml checks consumers out at `path: ${{ matrix.consumer }}`, the UNDERSCORED
# label (`mcritchie_studio` for repo `mcritchie-studio`). No local run reproduces it, so this
# file BUILDS the CI layout. The beat must still ABORT on a real refusal
# (test/lib/release_archive_docs_refusal_test.rb); the repair is only in WHERE the sweep is
# pointed. REAL bin/archive-docs AND REAL GIT: a stubbed sweep ignores `--repo=` and stays
# green. Only the board and the artifact commit are faked.
# History: task resolve-hub-path-in-consumer.

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

  # The hub's ACTUAL doc sweep, copied in: bin/archive-docs plus every lib it requires, because
  # `--repo=` is the variable under test. THE LIST IS DERIVED from the script's requires, NOT
  # WRITTEN DOWN: a literal list breaks with a LoadError inside the fixture when the script
  # grows a require, a fixture failure wearing the costume of a consumer-checkout failure.
  # History: task resolve-hub-path-in-consumer.
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

  # One unreferenced frozen snapshot to retire.
  def plant_docs(hub)
    FileUtils.mkdir_p(File.join(hub, "docs", "agents", "audits"))
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

  # Spawn the REAL bin/release.rb from INSIDE the fixture checkout (mirroring consumer-ci's
  # `working-directory: ${{ matrix.consumer }}`, which makes the cwd-relative `bin/archive-docs`
  # spawn resolve), with the projects root pinned at the fixture workspace. PROJECTS_DIR is
  # bin/release's documented seam for a non-default layout, not a test-only backdoor. The fix
  # must choose the directory NAME, the only thing left varying here.
  # History: task resolve-hub-path-in-consumer.
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
      def commit_artifact_to_accepted(*)
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

      # And it did real work there: the frozen snapshot moved, and the beat reached the
      # artifact commit.
      assert_includes out, "Retired 1 frozen doc(s)", "the retirement half ran:\n#{out}"
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
  # pinned. (Mirrors the release CLI harness's eval_helper; kept local because the
  # harness is a frozen hotspot in config/test_health.yml.)
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
