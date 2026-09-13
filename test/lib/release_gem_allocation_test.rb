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
require_relative "../support/session_env"

class ReleaseGemAllocationTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The child takes the ship-workspace flock, so it must never reach the
  # operator's real agent-locks store — under `bin/rails test` the task-usage
  # sandbox REFUSES that outright (the failure reads "MCR_PRIMARY_LOCK_DIR is
  # unset"), and by hand it would contend with a live `bin/release`. Memoized so
  # each forked worker gets its own, removed after the run. Same discipline as
  # ReleaseCliTest.lock_dir.
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("gem-alloc-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # Every child env is built HERE, through SessionEnv, so an ambient agent
  # session can never leak into a subprocess that runs real git.
  #
  # BUNDLER IS SCRUBBED TOO, and that one is not optional. Under `bin/rails test`
  # the parent exports `RUBYOPT=-rbundler/setup` + `BUNDLE_GEMFILE`, so the child
  # loads Bundler at startup — and Bundler PREPENDS ITS OWN BIN DIR TO `PATH`,
  # which shadowed the `bundle` stub below with the real one. The real `bundle
  # lock` then ran against THIS WORKTREE'S Gemfile (it printed "Writing lockfile
  # to …/wire-gem-version-allocation/Gemfile.lock") and every stubbed-misbehaviour
  # test silently exercised a healthy bundler instead. Running the child outside
  # the suite's bundler context is also simply correct: `bin/release` runs as a
  # plain CLI in production, not inside a test's bundle.
  BUNDLER_ENV_KEYS = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP].freeze

  def child_env(root, stub_bin)
    scrubbed = BUNDLER_ENV_KEYS.to_h { |key| [key, nil] }
    SessionEnv.neutralized(
      scrubbed.merge(
        "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}",
        "PROJECTS_DIR" => root,
        "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir
      )
    )
  end

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
  #
  # `changelog:` is nil by DEFAULT — a repo tracking no CHANGELOG.md — so every
  # test written before the roll landed keeps exercising exactly the tree it was
  # written against, and the absent-file path stays covered by all of them.
  def build_projects_root(root, version: "0.4.0", tracked_lock: true, changelog: nil)
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
    File.write(File.join(repo, "CHANGELOG.md"), changelog) if changelog
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
  #
  # WRITTEN IN RUBY, not shell, and that is not a style choice. The first version
  # of this stub used `sed -i '' …`, which is BSD syntax: on macOS it edits in
  # place, on GNU sed (Linux CI) the empty `''` is consumed as the SCRIPT and the
  # real script becomes a filename ("sed: can't read s/^    studio-engine…").
  # The stub then silently did nothing, the lock genuinely never moved, and the
  # read-back guard correctly refused — so five tests went red on CI and green on
  # macOS. The guard was right; the harness was lying. Ruby has one dialect.
  def install_bundle_stub(root, mode: :real)
    dir = File.join(root, "stub-bin")
    FileUtils.mkdir_p(dir)
    body =
      case mode
      when :real
        <<~RUBY
          version = File.read("lib/studio/version.rb")[/VERSION = "([^"]+)"/, 1]
          lock = "Gemfile.lock"
          File.write(lock, File.read(lock).sub(/^    studio-engine \\(.*\\)$/, "    studio-engine (\#{version})"))
        RUBY
      when :stale then "# succeed, change nothing\n"
      when :fail  then %($stderr.puts("Could not resolve dependencies")\nexit 1\n)
      end
    File.write(File.join(dir, "bundle"), "#!/usr/bin/env ruby\n#{body}")
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
    out, status = Open3.capture2e(child_env(root, stub_bin), RbConfig.ruby, "-W0", "-e", script)
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

  # --- the harness proves itself first -----------------------------------------
  #
  # A stub that silently does nothing turns every guard test below into a test of
  # the stub's failure instead of the guard's success — which is exactly what the
  # BSD `sed -i ''` version did on CI, in the direction that LOOKED like the
  # production code was broken. So the stub's effect is asserted directly, and a
  # future portability break fails HERE, loudly, instead of five tests down.
  def test_the_bundle_stub_reproduces_the_measured_bundle_lock_behaviour
    with_root do |root|
      _, repo = build_projects_root(root)
      File.write(File.join(repo, "lib", "studio", "version.rb"), %(module Studio\n  VERSION = "9.9.9"\nend\n))

      real = install_bundle_stub(root, mode: :real)
      _, status = Open3.capture2e({ "PATH" => "#{real}:#{ENV.fetch('PATH')}" }, "bundle", "lock", chdir: repo)

      assert status.success?, "the :real stub must exit 0"
      assert_includes File.read(File.join(repo, "Gemfile.lock")), "studio-engine (9.9.9)",
                      "the :real stub must rewrite the PATH spec — if it does not, every guard test below is vacuous"

      stale = install_bundle_stub(root, mode: :stale)
      Open3.capture2e({ "PATH" => "#{stale}:#{ENV.fetch('PATH')}" }, "bundle", "lock", chdir: repo)

      assert_includes File.read(File.join(repo, "Gemfile.lock")), "studio-engine (9.9.9)",
                      "the :stale stub must leave the lock exactly as it found it"
    end
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

  # --- the CHANGELOG roll, against real git ------------------------------------
  #
  # The transform, the dialects and the guard are unit-tested in
  # test/models/release/changelog_test.rb. What is tested HERE is everything the
  # pure module cannot see: that the file is read from origin/release, that the
  # rolled text is PUSHED, that it rides the SAME commit as the version and the
  # lock, and that a refusal leaves origin/release exactly as it found it.

  # A changelog whose newest heading is `heading`, holding one entry in the bucket.
  def changelog(heading: "## 0.4.0 — 2026-08-01", entries: ["### Fixed", "", "- entry one"])
    lines = ["# Changelog", "", "## Unreleased", ""]
    lines += entries + [""] unless entries.empty?
    lines += [heading, "", "- older entry"]
    "#{lines.join("\n")}\n"
  end

  def today = Time.now.strftime("%Y-%m-%d")

  def test_the_version_commit_carries_the_rolled_changelog
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog)
      out, ok = allocate(root, members: [member(kind: "feature")])

      assert ok, "allocation should have succeeded:\n#{out}"
      rolled = pushed(origin, "CHANGELOG.md")

      assert_includes rolled, "## 0.5.0 — #{today}", "the allocated version must reach the file that was PUSHED"
      assert_includes rolled, "- entry one", "the entry must survive the move"
      assert_operator rolled.index("## 0.5.0"), :<, rolled.index("- entry one"),
                      "the entry must end up UNDER the new heading, not above it"
      assert_operator rolled.index("## Unreleased"), :<, rolled.index("## 0.5.0"),
                      "the bucket stays first, empty, ready for the next cycle"

      # ONE commit, all three files. Asserting the commit's file LIST (not just
      # each file's contents) is the load-bearing half — two commits would satisfy
      # a contents-only check while letting the changelog land on a SHA whose
      # version contradicts it.
      files = git(origin, "show", "--name-only", "--format=", "release").split("\n").map(&:strip).reject(&:empty?)
      assert_equal %w[CHANGELOG.md Gemfile.lock lib/studio/version.rb], files.sort
    end
  end

  # THE DIALECT SURVIVES THE REAL PATH. turf-vault's bracketed/hyphen form, read
  # off the real file on 2026-09-09. A roll that imposed one house style would
  # put a second dialect into a repo's own file and break its structure test.
  def test_the_roll_writes_the_repos_own_heading_dialect
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(heading: "## [0.4.0] - 2026-08-01"))
      _, ok = allocate(root, members: [member(kind: "feature")])

      assert ok
      assert_includes pushed(origin, "CHANGELOG.md"), "## [0.5.0] - #{today}"
    end
  end

  # A release that documented nothing still earns its heading — that is what keeps
  # "the newest heading names the newest published version" exact, and what makes
  # an undocumented release visible instead of a silent gap in the numbering.
  def test_an_empty_bucket_still_records_the_release
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(entries: []))
      out, ok = allocate(root, members: [member(kind: "feature")])

      assert ok, out
      assert_includes pushed(origin, "CHANGELOG.md"), "## 0.5.0 — #{today}"
      assert_includes out, "no entries — the heading records the release"
    end
  end

  # A gem tracking no CHANGELOG.md is NOT refused — the registry declares no
  # changelog key, so its absence breaks no stated contract. It says so out loud
  # rather than passing in silence.
  def test_a_gem_with_no_changelog_still_allocates
    with_root do |root|
      origin, = build_projects_root(root)
      out, ok = allocate(root, members: [member(kind: "feature")])

      assert ok, out
      assert_includes out, "no CHANGELOG.md"
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "0.5.0")
    end
  end

  # THE GUARD, at the call site. A file already carrying a backlog cannot be
  # rolled honestly — stamping several releases of entries with one new version is
  # a bigger false statement than the one it replaces — so the sweep aborts in the
  # DECIDE phase with nothing written and nothing published.
  def test_a_backlogged_changelog_refuses_and_writes_nothing
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(heading: "## 0.1.0 — 2026-01-01"))
      out = assert_refuses(root, origin, "BACKLOG", members: [member(kind: "feature")])

      assert_includes out, "3 minor version(s)"
      assert_includes out, "NOTHING was published"
      assert_includes pushed(origin, "lib/studio/version.rb"), %(VERSION = "0.4.0"),
                      "the version must not have moved either — the refusal is in the decide phase"
    end
  end

  # A bucket that holds nothing has no history to mis-file, so a backlog alone
  # must not hold the sweep. The pair with the test above is what keeps the guard
  # aimed at the HARM rather than at the number.
  def test_a_backlog_with_an_empty_bucket_does_not_hold_the_sweep
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(heading: "## 0.1.0 — 2026-01-01", entries: []))
      _, ok = allocate(root, members: [member(kind: "feature")])

      assert ok
      assert_includes pushed(origin, "CHANGELOG.md"), "## 0.5.0 — #{today}"
    end
  end

  # A changelog the parser cannot read is refused rather than rolled into blind.
  # THE FLOOR IS A PROPERTY, NOT A COUNT: a guard that carries a hard-coded
  # heading count is tuned to one repo's history, and copying that number into a
  # repo with fewer headings makes it unfireable — the guard then passes
  # vacuously, which is the failure the floor was added to catch. Here every '## '
  # heading below the bucket must PARSE, so a two-heading fixture proves the same
  # property a hundred-heading one would.
  def test_an_unreadable_changelog_refuses_rather_than_rolling_blind
    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(heading: "## Release 0.4.0"))
      out = assert_refuses(root, origin, "parse as neither a version nor the Unreleased bucket",
                           members: [member(kind: "feature")])

      assert_includes out, "Release 0.4.0", "the refusal must name the line it could not read"
    end
  end

  # FENCED CODE IS CONTENT, THROUGH THE REAL PUSH PATH. The unit tier owns the
  # parse matrix (test/models/release/changelog_test.rb); what is proved here is
  # that the file which actually reaches origin/release carries it. A builder
  # documenting this very change quotes the heading the roll writes inside a
  # fenced block; before fence awareness the bucket was cut at that line, a blank
  # was injected inside the fence, and everything below it was filed under a
  # version that had already shipped — in the commit that PRECEDES `gem push`.
  def test_a_fenced_heading_in_the_bucket_is_rolled_whole
    fenced = ["### Fixed", "",
              "- prepare rolls the bucket. The heading it writes:", "",
              "```markdown",
              "## 0.3.0 — 2026-07-01",
              "```", "",
              "- and a trailing bullet"]

    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(entries: fenced))
      out, ok = allocate(root, members: [member(kind: "feature")])

      assert ok, "a quoted heading must not hold the sweep:\n#{out}"
      rolled = pushed(origin, "CHANGELOG.md")

      assert_equal 1, rolled.scan("## 0.3.0 — 2026-07-01").size,
                   "the quoted heading must stay quoted — never promoted to a second section"
      assert_operator rolled.index("## 0.5.0 — #{today}"), :<, rolled.index("- and a trailing bullet"),
                      "the entry BELOW the fence must land under the new heading, not the old one"
      assert_includes rolled, "```markdown\n## 0.3.0 — 2026-07-01\n```",
                      "the fence must arrive byte-for-byte, with nothing written inside it"
    end
  end

  # THE REFUSING HALF. An unterminated fence has no honest reading — a renderer
  # takes the rest of the file as code — so prepare refuses in the DECIDE phase
  # and origin/release is left exactly as it was found.
  def test_an_unterminated_fence_refuses_before_anything_is_written
    unclosed = ["### Fixed", "",
                "```markdown",
                "## 0.4.0 — 2026-08-01", "",
                "- a bullet whose fence was never closed"]

    with_root do |root|
      origin, = build_projects_root(root, changelog: changelog(entries: unclosed))
      out = assert_refuses(root, origin, "unterminated fenced code block",
                           members: [member(kind: "feature")])

      assert_includes out, "```markdown", "the refusal must name the opener it could not find a close for"
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
      assert_includes pushed(solana_origin, "lib/solana_studio/version.rb"), %(VERSION = "0.1.0")
    end
  end

  # A second registered gem, with no tracked Gemfile.lock.
  #
  # Its version_file was `solana-studio.gemspec` until 2026-08-20 — this fixture
  # existed partly to cover that gemspec-shaped `spec.version =` declaration.
  # The gem moved to a dedicated lib/solana_studio/version.rb (bin/dor-check
  # refuses a PR editing the registered version_file, which while it WAS the
  # gemspec locked spec.files and the dependencies too), so this fixture follows
  # the registry. Both declaration shapes keep direct coverage in
  # test/models/release/gem_version_test.rb, where rewrite_version is exercised
  # as the pure function it is — a better home for it than a git-fixture sweep.
  def build_solana_repo(root)
    origin = File.join(root, "solana-studio-origin.git")
    repo   = File.join(root, "solana-studio")
    Open3.capture2e("git", "init", "--quiet", "--bare", origin)
    Open3.capture2e("git", "init", "--quiet", "-b", "release", repo)
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "commit.gpgsign", "false")
    FileUtils.mkdir_p(File.join(repo, "lib", "solana_studio"))
    File.write(File.join(repo, "lib/solana_studio/version.rb"),
               %(module SolanaStudio\n  VERSION = "0.1.0"\nend\n))
    File.write(File.join(repo, "solana-studio.gemspec"),
               %(require_relative "lib/solana_studio/version"\nGem::Specification.new do |spec|\n  spec.version = SolanaStudio::VERSION\nend\n))
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
    out, status = Open3.capture2e(child_env(root, stub_bin), RbConfig.ruby, "-W0", "-e", script)
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

  # --- a publish whose tag push failed (/tasks/untagged-gem-publish-strands-work)
  #
  # publish_gem pushes the gem, then tags and pushes the tag, and a failed tag push
  # is NON-FATAL. The gem is live; origin has no tag. From any clone without that
  # tag, allocation reads version > tag and SKIPs as "allocated already", phase 2
  # skips the already-live publish, and the work promoted after it never ships.
  # This rebuilds that state for real: origin REJECTS the tag push.
  def publish_without_tag(origin, repo, version:)
    File.write(File.join(repo, "lib", "studio", "version.rb"), %(module Studio\n  VERSION = "#{version}"\nend\n))
    File.write(File.join(repo, "Gemfile.lock"), lockfile(version))
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "Release #{version}")
    git(repo, "push", "--quiet", "origin", "release")

    hook = File.join(origin, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\nwhile read old new ref; do case \"$ref\" in refs/tags/*) " \
                     "echo \"tag pushes refused\" >&2; exit 1;; esac; done\n")
    FileUtils.chmod(0o755, hook)
    git(repo, "tag", "-a", "v#{version}", "-m", "Release studio-engine v#{version}")
    _, pushed = Open3.capture2e("git", "-C", repo, "push", "origin", "v#{version}")
    refute pushed.success?, "the harness must really fail the tag push"

    File.write(File.join(repo, "lib", "studio", "later.rb"), "# promoted after the publish\n")
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", "work promoted after #{version} published")
    git(repo, "push", "--quiet", "origin", "release")
  end

  def test_a_publish_whose_tag_push_failed_refuses_instead_of_skipping
    with_root do |root|
      origin, repo = build_projects_root(root)
      publish_without_tag(origin, repo, version: "0.5.0")
      git(repo, "tag", "-d", "v0.5.0") # a clone that lacks the tag, as origin does
      before = git(origin, "rev-parse", "release").strip

      out, ok = allocate(root, members: [member], live: %w[0.4.0 0.5.0])

      refute ok, "a live version with no tag must stop the sweep, not skip it:\n#{out}"
      assert_includes out, "REFUSING to allocate"
      assert_includes out, "v0.5.0"
      refute_includes out, "nothing allocated", "the silent SKIP is the defect"
      assert_equal before, git(origin, "rev-parse", "release").strip, "a refusal writes nothing"
    end
  end

  # Why the refusal has to live in allocation: the stranded-work guard, the
  # documented backstop, is blind to this state by construction (it fires only
  # when the version did NOT advance past the tag).
  def test_the_stranded_work_guard_does_not_see_a_failed_tag_push
    with_root do |root|
      origin, repo = build_projects_root(root)
      publish_without_tag(origin, repo, version: "0.5.0")
      git(repo, "tag", "-d", "v0.5.0")
      tip = git(origin, "rev-parse", "release").strip
      script = "ENV['PROJECTS_DIR'] = #{root.inspect}\nload #{BIN.inspect}\n" \
               "p stranded_gem_failure('studio-engine', #{repo.inspect}, #{tip.inspect}, '0.5.0')"

      out, status = Open3.capture2e(child_env(root, install_bundle_stub(root)), RbConfig.ruby, "-W0", "-e", script)

      assert status.success?, out
      assert_equal "nil", out.strip.lines.last.to_s.strip, "the guard passes this state — which is the hole"
    end
  end

  # The control: the clone that ran the publish keeps its tag locally, reads
  # version == tag, and allocates the next number normally.
  def test_the_publishing_clone_that_kept_its_tag_still_allocates
    with_root do |root|
      origin, repo = build_projects_root(root)
      publish_without_tag(origin, repo, version: "0.5.0")

      out, ok = allocate(root, members: [member], live: %w[0.4.0 0.5.0])

      assert ok, out
      assert_includes out, "allocated 0.6.0"
    end
  end
end
