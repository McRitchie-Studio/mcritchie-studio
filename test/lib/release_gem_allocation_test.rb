# frozen_string_literal: true

# [integration] bin/release prepare's step-4d gem version ALLOCATION — the call
# site, against real git.
#
# The arithmetic is unit-tested in test/models/release/gem_version_test.rb. What
# is tested HERE is everything the pure module cannot see: that a real candidate's
# membership reaches it, that the number it returns is written into the real
# version_file, that the commit carries the Gemfile.lock beside it, and that a
# refusal leaves origin/release exactly as it found it.
#
# REAL, not mocked: a bare origin, a clone, a tag, a commit past the tag, and
# bin/release's own workspace/commit/push path. Two things are stubbed, both
# because they are network:
#
#   * `rubygems_versions` — redefined after `load` to return a fixed live list.
#   * `bundle` — a stub on PATH. The REAL `bundle lock` behaviour it stands in for
#     was MEASURED on studio-engine (0.38.0 → 0.39.0 rewrites the `PATH remote: .`
#     spec and nothing else — a one-line diff), and the stub reproduces exactly
#     that. Its point is that the stub can also be told to MISBEHAVE, which is how
#     the lockfile guard below is proven to actually bite.
#
#   ruby -Itest test/lib/release_gem_allocation_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

class ReleaseGemAllocationTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # A self-bundling gem's lockfile: studio-engine's real shape, where the gem's
  # OWN version lives in a PATH section and never in a GEM one. This is the trap
  # the commit has to carry — CI installs frozen, so a version_file that moves
  # without this file fails `bundle install` before running a single test.
  def lockfile(version)
    <<~LOCK
      PATH
        remote: .
        specs:
          studio-engine (#{version})
            rails (>= 7.2)

      GEM
        remote: https://rubygems.org/
        specs:
          rails (7.2.1)

      DEPENDENCIES
        studio-engine!
    LOCK
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed in #{dir}: #{out}" unless status.success?

    out
  end

  # A projects root holding a bare `origin` and a `studio-engine` clone whose
  # `release` branch is tagged v<version> and then carries one commit PAST the
  # tag — the exact state a swept gem member is in at step 4d.
  def build_projects_root(root, version: "0.4.0", tracked_lock: true)
    origin = File.join(root, "studio-engine-origin.git")
    repo   = File.join(root, "studio-engine")
    Open3.capture2e("git", "init", "--quiet", "--bare", origin)
    Open3.capture2e("git", "init", "--quiet", "-b", "release", repo)
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "commit.gpgsign", "false")

    FileUtils.mkdir_p(File.join(repo, "lib", "studio"))
    File.write(File.join(repo, "lib", "studio", "version.rb"), %(module Studio\n  VERSION = "#{version}"\nend\n))
    File.write(File.join(repo, "Gemfile.lock"), lockfile(version)) if tracked_lock
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "seed #{version}")
    git(repo, "tag", "v#{version}")
    git(repo, "remote", "add", "origin", origin)
    git(repo, "push", "--quiet", "origin", "release", "--tags")

    # The member's work: a commit past the last published tag, which is what makes
    # this gem publishable at all.
    File.write(File.join(repo, "lib", "studio", "feature.rb"), "# shipped work\n")
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "add a feature")
    git(repo, "push", "--quiet", "origin", "release")
    [origin, repo]
  end

  # The `bundle` stub. `mode`:
  #   :real    — rewrite the PATH spec from the version file, as measured.
  #   :stale   — succeed and change NOTHING (RubyGems-propagation-shaped: the
  #              exact failure `bundle lock` reports success for).
  #   :fail    — exit non-zero.
  def install_bundle_stub(root, mode: :real)
    dir = File.join(root, "stub-bin")
    FileUtils.mkdir_p(dir)
    body =
      case mode
      when :real
        <<~SH
          v=$(sed -n 's/.*VERSION = "\\([^"]*\\)".*/\\1/p' lib/studio/version.rb)
          sed -i '' "s/^    studio-engine (.*)$/    studio-engine ($v)/" Gemfile.lock
          exit 0
        SH
      when :stale then "exit 0\n"
      when :fail  then "echo 'Could not resolve dependencies' >&2\nexit 1\n"
      end
    File.write(File.join(dir, "bundle"), "#!/bin/sh\n#{body}")
    FileUtils.chmod(0o755, File.join(dir, "bundle"))
    dir
  end

  # Drive the real `allocate_gem_versions!` in a subprocess that has `load`ed
  # bin/release.rb (its dispatch is guarded on __FILE__ == $PROGRAM_NAME, so
  # loading defines the helpers without running a command).
  def allocate(root, members:, live: ["0.4.0"], stub: :real)
    stub_bin = install_bundle_stub(root, mode: stub)
    script = <<~RUBY
      ENV["PROJECTS_DIR"] = #{root.inspect}
      load #{BIN.inspect}
      # The one network read, stubbed. Redefining after load overrides the real one.
      def rubygems_versions(_gem) = JSON.parse(#{live.to_json.inspect})
      allocate_gem_versions!([{ "repo" => "studio-engine", "members" => #{members.inspect} }])
    RUBY
    env = { "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}", "PROJECTS_DIR" => root }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-W0", "-e", script)
    [out, status.success?]
  end

  def member(kind: "feature", risk: [], bump: "", slug: "engine-task")
    { "slug" => slug, "task_kind" => kind, "risk_tags" => risk, "gem_bump" => bump }
  end

  # What origin/release actually holds now — read from the BARE repo, so this
  # asserts what was PUSHED, never what a local tree happens to say.
  def pushed(origin, path)
    git(origin, "show", "release:#{path}")
  end

  def with_root
    Dir.mktmpdir("gem-alloc") { |root| yield root }
  end

  # --- the happy path ----------------------------------------------------------

  def test_allocates_the_members_bump_and_pushes_it_to_origin_release
    with_root do |root|
      origin, = build_projects_root(root)
      out, ok = allocate(root, members: [member(kind: "feature")])

      assert ok, "allocation should have succeeded:\n#{out}"
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "0.5.0"),
                      "a feature member earns a minor over the published 0.4.0"
      assert_includes out, "allocated 0.5.0"
    end
  end

  def test_a_breaking_member_carries_the_release_to_a_major
    with_root do |root|
      origin, = build_projects_root(root)
      _, ok = allocate(root, members: [member(kind: "chore"), member(kind: "bug", risk: ["breaking"], slug: "b")])

      assert ok
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "1.0.0")
    end
  end

  # TRAP 1. The version and its lockfile must move in ONE commit: studio-engine
  # bundles itself, CI installs frozen, and a lockfile left behind fails the build
  # before a test runs. Asserting the commit's file list (not just the file
  # contents) is deliberate — two commits would satisfy a contents-only check
  # while still letting the version land on a SHA whose lock contradicts it.
  def test_the_version_commit_carries_the_gemfile_lock
    with_root do |root|
      origin, = build_projects_root(root)
      _, ok = allocate(root, members: [member(kind: "feature")])

      assert ok
      assert_includes pushed(origin, "Gemfile.lock"), "studio-engine (0.5.0)",
                      "the self-bundled PATH spec must move with the version"

      files = git(origin, "show", "--name-only", "--format=", "release").split("\n").map(&:strip).reject(&:empty?)
      assert_equal %w[Gemfile.lock lib/studio/version.rb], files.sort,
                   "one commit, both files — not a version commit with the lock trailing behind"
    end
  end

  # A gem that tracks no Gemfile.lock (solana-studio) must still allocate. The
  # lock step is conditional on the file being TRACKED, never on it existing.
  def test_a_gem_without_a_tracked_lockfile_still_allocates
    with_root do |root|
      origin, = build_projects_root(root, tracked_lock: false)
      _, ok = allocate(root, members: [member(kind: "bug")], stub: :fail)

      assert ok, "no tracked lock means `bundle` is never run — a broken bundle must not matter here"
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "0.4.1")
    end
  end

  # --- idempotency: the self-healing re-run ------------------------------------

  def test_a_second_run_allocates_nothing
    with_root do |root|
      origin, = build_projects_root(root)
      _, ok = allocate(root, members: [member(kind: "feature")])
      assert ok
      first = git(origin, "rev-parse", "release").strip

      out, ok2 = allocate(root, members: [member(kind: "feature")])

      assert ok2
      assert_includes out, "already advanced"
      assert_equal first, git(origin, "rev-parse", "release").strip,
                   "a re-run must not burn a second version number"
    end
  end

  # --- refusing rather than guessing -------------------------------------------
  #
  # Every case below must abort AND leave origin/release untouched. The
  # unchanged-SHA assertion is the load-bearing half: a refusal that had already
  # pushed something would be no refusal at all.

  def assert_refuses(root, origin, expected, **allocate_args)
    before = git(origin, "rev-parse", "release").strip
    out, ok = allocate(root, **allocate_args)

    refute ok, "expected the sweep to abort:\n#{out}"
    assert_includes out, expected
    assert_equal before, git(origin, "rev-parse", "release").strip,
                 "a refusal must leave origin/release exactly as it found it"
    out
  end

  def test_refuses_an_unreadable_gem_bump_override
    with_root do |root|
      origin, = build_projects_root(root)
      out = assert_refuses(root, origin, "REFUSING", members: [member(bump: "mjaor")])

      assert_includes out, "mjaor"
      assert_includes out, "NOTHING was published"
    end
  end

  def test_refuses_when_the_candidate_carries_no_members
    with_root do |root|
      origin, = build_projects_root(root)
      assert_refuses(root, origin, "no gem members", members: [])
    end
  end

  # TRAP 1, MUTATED. `bundle lock` exits 0 whether or not it did anything, so a
  # guard that trusted its exit status would pass here and commit a version its
  # own lockfile contradicts. The stub succeeds and changes nothing; the read-back
  # must catch it. If this test ever goes green with the read-back removed, the
  # guard is decorative.
  def test_refuses_when_bundle_lock_succeeds_but_the_lock_did_not_move
    with_root do |root|
      origin, = build_projects_root(root)
      out = assert_refuses(root, origin, "wanted 0.5.0", members: [member(kind: "feature")], stub: :stale)

      assert_includes out, %(resolving "0.4.0"), "the refusal must name what the lock ACTUALLY resolves"
    end
  end

  def test_refuses_when_bundle_lock_fails
    with_root do |root|
      origin, = build_projects_root(root)
      assert_refuses(root, origin, "`bundle lock` failed", members: [member(kind: "feature")], stub: :fail)
    end
  end

  # --- decide every gem BEFORE writing to any of them --------------------------
  #
  # The "mutate before validate" objection that got allocation descoped when the
  # module first shipped (finding-d0621629719b). Phase 0a decides for the whole
  # sweep and phase 0b writes, so one gem's refusal must leave the OTHER gem's
  # release branch untouched. Interleaved loops pass every other test in this
  # file and fail only this one.
  def test_a_refusal_on_one_gem_writes_nothing_to_the_other
    with_root do |root|
      engine_origin, = build_projects_root(root)
      solana_origin  = build_solana_repo(root)
      before_engine  = git(engine_origin, "rev-parse", "release").strip

      out, ok = allocate_both(root,
                              engine: [member(kind: "feature")],
                              solana: [member(kind: "feature", bump: "mnior", slug: "solana-task")])

      refute ok, "the sweep must abort on solana-studio's unreadable override:\n#{out}"
      assert_includes out, "mnior"
      assert_equal before_engine, git(engine_origin, "rev-parse", "release").strip,
                   "studio-engine must not have been written — its sibling had not been judged yet"
      assert_includes pushed(solana_origin, "solana-studio.gemspec"), %(spec.version       = "0.1.0")
    end
  end

  # A second registered gem, with the OTHER registered version_file shape (a
  # gemspec) and no tracked Gemfile.lock.
  def build_solana_repo(root)
    origin = File.join(root, "solana-studio-origin.git")
    repo   = File.join(root, "solana-studio")
    Open3.capture2e("git", "init", "--quiet", "--bare", origin)
    Open3.capture2e("git", "init", "--quiet", "-b", "release", repo)
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "commit.gpgsign", "false")
    File.write(File.join(repo, "solana-studio.gemspec"),
               %(Gem::Specification.new do |spec|\n  spec.version       = "0.1.0"\nend\n))
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "seed 0.1.0")
    git(repo, "tag", "v0.1.0")
    git(repo, "remote", "add", "origin", origin)
    git(repo, "push", "--quiet", "origin", "release", "--tags")
    File.write(File.join(repo, "work.rb"), "# shipped work\n")
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "add a feature")
    git(repo, "push", "--quiet", "origin", "release")
    origin
  end

  def allocate_both(root, engine:, solana:)
    stub_bin = install_bundle_stub(root, mode: :real)
    script = <<~RUBY
      ENV["PROJECTS_DIR"] = #{root.inspect}
      load #{BIN.inspect}
      def rubygems_versions(gem_name)
        gem_name == "studio-engine" ? [{ "number" => "0.4.0" }] : [{ "number" => "0.1.0" }]
      end
      allocate_gem_versions!([
        { "repo" => "studio-engine", "members" => #{engine.inspect} },
        { "repo" => "solana-studio", "members" => #{solana.inspect} }
      ])
    RUBY
    env = { "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}", "PROJECTS_DIR" => root }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-W0", "-e", script)
    [out, status.success?]
  end

  # The baseline is the highest of the tag AND the live list, so a tag that lags
  # a publish can never re-tread a live number.
  def test_never_allocates_a_version_rubygems_already_has
    with_root do |root|
      origin, = build_projects_root(root)
      _, ok = allocate(root, members: [member(kind: "feature")], live: %w[0.4.0 0.5.0 0.6.0])

      assert ok
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "0.7.0"),
                      "0.5.0 and 0.6.0 are published and can never be re-pushed"
    end
  end
end
