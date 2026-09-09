require "minitest/autorun"
require "open3"
require "tmpdir"

# The PRODUCER lock bump and its drift post-condition, driven for real — the
# SHELL half of the step the sweep takes right after it bumps its consumers.
#
# THE DEFECT THIS FILE EXISTS FOR. `bump_consumer_locks_for_qa` walks `app_groups`
# — the release's APP members. studio-engine is registered as a `gem`, so it never
# entered that loop, even though its own Gemfile declares `solana-studio`. Every
# publish therefore left the engine's lock trailing, and the engine's own
# consumer-ci lane (`bin/gem-drift-check`) reddened EVERY open engine PR over a
# line no PR author owns. Measured 2026-09-09: engine lock on solana-studio 0.9.0
# against a published 0.9.1, with PRs #313 and #245 both red on
# `Check this engine does not trail turf_monster`.
#
# A NEW FILE ON PURPOSE: test/lib/release_cli_test.rb is frozen at its size by
# config/test_health.yml (7669), precisely so new work lands somewhere else. This
# follows test/lib/release_engine_migration_install_test.rb's pattern — the REAL
# function runs, with `sh`/`git_capture` stubbed, so the decisions under test are
# the ones the shell actually makes rather than a model's idea of them.
class ReleaseProducerLockBumpTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # Records every command, answers the handful the step reads. Tests set
  # GEMFILE_TEXT / PUSH_OK before this is evaluated.
  STUB = <<~'RUBY'
    GEMFILE_TEXT = %(gem "solana-studio", ">= 0.5.3"\n) unless defined?(GEMFILE_TEXT)
    PUSH_OK = true unless defined?(PUSH_OK)

    $WORKSPACE = Dir.mktmpdir
    File.write(File.join($WORKSPACE, "Gemfile"), GEMFILE_TEXT)

    # Every gem repo "exists" as a sibling; the workspace is the tmpdir above.
    def repo_path(repo) = $WORKSPACE
    def with_ship_workspace(_repo, &block) = block.call
    def ship_workspace!(_repo, _sha) = $WORKSPACE
    def bundle_lock(*a, **k)
      $stdout.puts("LOCKED: #{a[1]} expect=#{k[:expect]}")
    end
    def install_engine_migrations!(*) = nil

    def sh(*a, **k)
      cmd = a.reject { |x| x.is_a?(Hash) }.join(" ")
      $stdout.puts("RAN: #{cmd}")
      return ["", PUSH_OK] if cmd.include?("push")
      ["", true]
    end

    def git_capture(*a)
      j = a.join(" ")
      $stdout.puts("GIT: #{j}")
      return ["deadbeef", true] if j.include?("rev-parse")
      # A dirty tree, so the step reaches its commit + push.
      return [" M Gemfile.lock", true] if j.include?("status --porcelain")
      ["", true]
    end
  RUBY

  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  # ── THE DECISIVE PROPERTY ────────────────────────────────────────────────────
  #
  # The bump lands on `accepted`, NOT `release`. This is the whole reason the step
  # is separate rather than more entries in `app_groups`: a gem repo's PRs are
  # based on `accepted` and that is the tree `bin/gem-drift-check` reads. Retarget
  # this at `release` — the branch the consumer bump correctly uses — and every
  # open engine PR stays exactly as red as before, while the sweep reports success.
  # `bin/release` writes `accepted` NOWHERE else, and nothing merges `release` back
  # down, so there is no second path by which the fix could arrive.
  def test_it_commits_the_producer_bump_onto_accepted_not_release
    out = run_release(STUB, %(bump_producer_locks_for_accepted({ "solana-studio" => "0.9.1" })))

    assert_includes out, "RAN: git", "sanity: commands were recorded at all: #{out}"
    assert_includes out, "HEAD:refs/heads/accepted",
                    "the producer lock bump MUST target accepted — that is where its PRs live: #{out}"
    refute_includes out, "HEAD:refs/heads/release",
                    "targeting release would leave every engine PR red: #{out}"
  end

  def test_it_bumps_the_lock_against_the_published_version
    out = run_release(STUB, %(bump_producer_locks_for_accepted({ "solana-studio" => "0.9.1" })))

    assert_includes out, "LOCKED: solana-studio expect=0.9.1",
                    "the lock must be ASSERTED at the published version, not inferred: #{out}"
    assert_includes out, "onto origin/accepted", "and the step must say what it did: #{out}"
  end

  # A producer never re-pins the gem it publishes. Both gem repos declare
  # themselves with `gemspec`, so this is belt and braces — but the reject is the
  # statement of intent, and a registry that ever gained a self-referencing Gemfile
  # must not make the sweep try to bump a repo to its own just-pushed version.
  def test_it_never_bumps_a_producer_for_the_gem_it_publishes
    out = run_release(STUB, %(bump_producer_locks_for_accepted({ "studio-engine" => "0.75.0" })))

    assert_includes out, "studio-engine: publishes studio-engine and consumes none of it",
                    "a gem must not re-pin itself: #{out}"
    refute_includes out, "LOCKED: studio-engine", "and must certainly not lock against its own push: #{out}"
  end

  # A producer whose Gemfile does not declare the published gem is a SKIP. Most
  # gems are not consumers of most other gems, and a skip must stay quiet enough
  # to be readable while still naming what it looked for.
  def test_it_skips_a_producer_that_does_not_declare_the_gem
    out = run_release(%(GEMFILE_TEXT = %(gem "rails"\\n)\n) + STUB,
                      %(bump_producer_locks_for_accepted({ "solana-studio" => "0.9.1" })))

    assert_includes out, "Gemfile does not declare solana-studio", "a non-consumer is skipped: #{out}"
    refute_includes out, "HEAD:refs/heads/accepted", "and nothing is pushed for it: #{out}"
  end

  # A failed push must NOT abort. The gems are already on RubyGems by the time
  # this runs, and stranding a candidate over a branch that moved would trade an
  # irreversible cost for a re-runnable one — prepare resumes.
  def test_a_failed_push_warns_and_continues_rather_than_stranding_the_candidate
    out = run_release(%(PUSH_OK = false\n) + STUB,
                      %(bump_producer_locks_for_accepted({ "solana-studio" => "0.9.1" }); puts("CONTINUED")))

    assert_includes out, "CONTINUED", "a push failure here must not abort a post-publish sweep: #{out}"
    assert_includes out, "could not push the producer lock bump", "but it must be loud: #{out}"
  end

  # ── THE POST-CONDITION ───────────────────────────────────────────────────────

  DRIFT_STUB = <<~'RUBY'
    ENGINE_LOCK = "0.9.0" unless defined?(ENGINE_LOCK)

    # The repo name must reach git_capture, and it only does so through the PATH —
    # so each repo gets its own (really existing, since the reader skips a repo
    # with no checkout) directory.
    require "fileutils"
    $ROOTS = Dir.mktmpdir
    %w[studio-engine solana-studio turf-monster].each { |r| FileUtils.mkdir_p(File.join($ROOTS, r)) }

    def repo_path(repo) = File.join($ROOTS, repo.to_s)
    def git_capture(*a)
      j = a.join(" ")
      if j.include?("Gemfile.lock")
        version = j.include?("studio-engine") ? ENGINE_LOCK : "0.9.1"
        return ["GEM\n  specs:\n    solana-studio (#{version})\n      ed25519 (~> 1.3)\n", true]
      end
      ["", true]
    end
  RUBY

  # MUTATION 1, at the shell tier: the engine trails, and the sweep must refuse to
  # walk on. Note there is no version LITERAL doing the deciding — the floor is
  # the published map this call supplies, so the next publish re-anchors it.
  def test_it_aborts_when_a_repo_still_trails_a_published_gem
    out = run_release(DRIFT_STUB,
                      %(assert_no_lock_drift!([{ "repo" => "turf-monster" }], { "solana-studio" => "0.9.1" })))

    assert_includes out, "ABORTED", "drift surviving the sweep's own repair must stop it: #{out}"
    assert_includes out, "studio-engine resolves solana-studio 0.9.0, published 0.9.1",
                    "and name the repo with both numbers: #{out}"
    assert_includes out, "ALREADY PUBLISHED",
                    "and warn that the publish is not the thing to retry: #{out}"
  end

  # MUTATION 2, at the shell tier: the producer LEADS. A gem repo tracking an
  # unreleased build of the gem it develops against is not drift, and the
  # correctly-bumped consumers beside it must not be flagged for its lead. Anchor
  # the floor on max(resolved) instead of on the published version and this test
  # goes red on a repo that did nothing wrong.
  def test_it_stays_silent_when_the_producer_LEADS_the_published_gem
    out = run_release(%(ENGINE_LOCK = "0.10.0"\n) + DRIFT_STUB,
                      %(assert_no_lock_drift!([{ "repo" => "turf-monster" }], { "solana-studio" => "0.9.1" }); puts("CLEAN")))

    assert_includes out, "CLEAN", "a producer ahead of the published gem is not drift: #{out}"
    assert_includes out, "lock drift: none", "and the sweep says so explicitly: #{out}"
    refute_includes out, "ABORTED", "no repo may be flagged for another repo's legitimate lead: #{out}"
  end

  def test_it_passes_when_every_repo_rests_on_the_published_version
    out = run_release(%(ENGINE_LOCK = "0.9.1"\n) + DRIFT_STUB,
                      %(assert_no_lock_drift!([{ "repo" => "turf-monster" }], { "solana-studio" => "0.9.1" }); puts("CLEAN")))

    assert_includes out, "CLEAN", "the aligned ecosystem is the happy path: #{out}"
    assert_includes out, "lock drift: none"
  end
end
