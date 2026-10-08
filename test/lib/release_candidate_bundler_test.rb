# frozen_string_literal: true

# How REAL Bundler treats a release candidate in a consumer's lock.
#   bin/rails test test/lib/release_candidate_bundler_test.rb
#
# bin/release prepare locks consumers to a prerelease (x.y.z.rcN) for QA and
# bin/release ship re-locks them to the final x.y.z. Both moves rest on two Bundler
# rules: a prerelease is resolved only when a requirement names one
# (Gem::Requirement#prerelease?, https://guides.rubygems.org/patterns/#prerelease-gems),
# and a lock keeps whatever still satisfies the Gemfile. This file runs the real
# `bundle lock` and a frozen `bundle install` against a gem source on disk, through
# the same transforms bin/release uses, so the rules are measured, not quoted.
#
# No network: the source is a file:// index this test writes, and the probe gem has
# no dependencies.
require "test_helper"
require "open3"
require "zlib"
require "rubygems/package"

class ReleaseCandidateBundlerTest < ActiveSupport::TestCase
  GEM = "pgaq-probe"
  R = Release::GemfileRepin
  S = Release::ShipSequence

  def setup
    @root = Dir.mktmpdir("candidate-bundler")
    @repo = File.join(@root, "repo")
    @app  = File.join(@root, "app")
    FileUtils.mkdir_p([File.join(@repo, "gems"), @app])
    @specs = []
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # Publish one version into the on-disk source and rewrite its legacy index, the
  # format Bundler reads from a file:// source.
  def publish(version)
    spec = Gem::Specification.new do |s|
      s.name = GEM
      s.version = version
      s.summary = "probe"
      s.authors = ["test"]
      s.files = []
    end
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Gem::Package.build(spec, true, false, File.join(@repo, "gems", "#{GEM}-#{version}.gem"))
    end
    @specs << spec
    quick = File.join(@repo, "quick", "Marshal.4.8")
    FileUtils.mkdir_p(quick)
    File.binwrite(File.join(quick, "#{GEM}-#{version}.gemspec.rz"), Zlib::Deflate.deflate(Marshal.dump(spec)))
    tuples = ->(list) { list.map { |s| [s.name, s.version, s.platform.to_s] } }
    released, pre = @specs.partition { |s| !s.version.prerelease? }
    { "specs" => released, "latest_specs" => released.last(1), "prerelease_specs" => pre }.each do |name, list|
      Zlib::GzipWriter.open(File.join(@repo, "#{name}.4.8.gz")) { |gz| gz.write(Marshal.dump(tuples.call(list))) }
    end
  end

  def gemfile(line)
    File.write(File.join(@app, "Gemfile"), %(source "file://#{@repo}"\n#{line}\n))
  end

  # The real `bundle`, outside this process's own bundle, writing only under @root.
  # Lock checksums are off: a file:// source has none to record, and Bundler 4
  # refuses a frozen install over an empty entry.
  def bundle(*args, env: {})
    scrub = ENV.keys.grep(/\A(BUNDLE_|BUNDLER_|RUBYOPT\z|RUBYLIB\z|GEM_HOME\z|GEM_PATH\z)/).to_h { |k| [k, nil] }
    scrub.merge!("BUNDLE_GEMFILE" => gemfile_path, "BUNDLE_APP_CONFIG" => File.join(@root, "config"),
                 "BUNDLE_USER_HOME" => File.join(@root, "home"), "BUNDLE_PATH" => File.join(@root, "vendor"),
                 "BUNDLE_FROZEN" => "false", "BUNDLE_LOCKFILE_CHECKSUMS" => "false")
    out, status = Open3.capture2e(scrub.merge(env), "bundle", *args, chdir: @app)
    assert_predicate status, :success?, "bundle #{args.join(' ')} failed:\n#{out}"
    out
  end

  def gemfile_path = File.join(@app, "Gemfile")
  def gemfile_text = File.read(gemfile_path)
  def write_gemfile(text) = File.write(gemfile_path, text)

  def locked
    File.read(File.join(@app, "Gemfile.lock"))[/^    #{GEM} \(([^)]+)\)$/, 1]
  end

  # What a CI runner or a Heroku build does with the committed tree: install
  # exactly the lock, refusing to change it, then load the gem.
  def frozen_install_loads
    bundle("install", env: { "BUNDLE_FROZEN" => "true" })
    bundle("exec", "ruby", "-e", %(print Gem.loaded_specs.fetch("#{GEM}").version), env: { "BUNDLE_FROZEN" => "true" }).lines.last.to_s.strip
  end

  # bin/release prepare's consumer bump, step for step (bump_consumer_locks_for_qa).
  def prepare_bump(candidate)
    committed = S.locked_gemfile(gemfile_text, GEM, candidate)
    write_gemfile(S.resolving_gemfile(committed, GEM, candidate))
    bundle("lock", "--update", GEM, "--conservative")
    write_gemfile(committed)
    bundle("lock")
    committed
  end

  # bin/release ship's re-lock (repin_consumers).
  def ship_relock(final)
    write_gemfile(S.locked_gemfile(gemfile_text, GEM, final))
    bundle("lock", "--update", GEM, "--conservative")
  end

  PLAIN = %(gem "#{GEM}", "~> 0.1")

  def source_line = %(source "file://#{@repo}"\n)

  # ── the three consumer shapes, each through prepare and then ship ──────────

  # A MINOR bump inside the pin: no Gemfile line changes at either step, so the
  # prepare commit and the ship commit are Gemfile.lock alone.
  def test_a_minor_bump_locks_the_candidate_then_the_final_without_touching_the_gemfile
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)
    bundle("lock")
    before = gemfile_text

    prepare_bump("0.2.0.rc1")
    assert_equal "0.2.0.rc1", locked
    assert_equal before, gemfile_text, "the committed Gemfile is byte for byte the one QA's branch already had"
    assert_equal "0.2.0.rc1", frozen_install_loads, "a frozen install accepts the candidate under the untouched pin"

    publish("0.2.0")
    ship_relock("0.2.0")
    assert_equal "0.2.0", locked
    assert_equal before, gemfile_text
    assert_equal "0.2.0", frozen_install_loads
  end

  # A MAJOR bump: the final's pin "~> 1.0" excludes 1.0.0.rc1, so the committed
  # line carries the candidate as its floor until the ship.
  def test_a_major_bump_locks_the_candidate_then_the_final
    publish("0.1.0")
    publish("1.0.0.rc1")
    gemfile(PLAIN)
    bundle("lock")

    prepare_bump("1.0.0.rc1")
    assert_equal "1.0.0.rc1", locked
    assert_equal source_line + %(gem "#{GEM}", ">= 1.0.0.rc1", "< 2"\n), gemfile_text
    assert_equal "1.0.0.rc1", frozen_install_loads

    publish("1.0.0")
    ship_relock("1.0.0")
    assert_equal "1.0.0", locked
    assert_equal source_line + %(gem "#{GEM}", "~> 1.0"\n), gemfile_text
    assert_equal "1.0.0", frozen_install_loads
  end

  # A BRANCH-SOURCED line (a consumer whose `accepted` tracks the gem's branch).
  # It starts with no lock here: a git-sourced lock would need the network.
  def test_a_branch_sourced_line_locks_the_candidate_then_the_final
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(%(gem "#{GEM}", github: "McRitchie-Studio/#{GEM}", branch: "feat/x"))

    prepare_bump("0.2.0.rc1")
    assert_equal "0.2.0.rc1", locked
    assert_equal source_line + %(gem "#{GEM}", ">= 0.2.0.rc1", "< 1"\n), gemfile_text
    assert_equal "0.2.0.rc1", frozen_install_loads

    publish("0.2.0")
    ship_relock("0.2.0")
    assert_equal "0.2.0", locked
    assert_equal source_line + %(gem "#{GEM}", "~> 0.2"\n), gemfile_text
    assert_equal "0.2.0", frozen_install_loads
  end

  # A QA bounce: rc2 replaces rc1 in the lock, by the same steps.
  def test_a_second_candidate_replaces_the_first
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)
    bundle("lock")
    prepare_bump("0.2.0.rc1")

    publish("0.2.0.rc2")
    prepare_bump("0.2.0.rc2")

    assert_equal "0.2.0.rc2", locked
  end

  # ── why each step is there ─────────────────────────────────────────────────

  # THE LINE THIS FLOW MUST NEVER WRITE: the final's pin beside its own candidate.
  def test_the_finals_pin_beside_its_candidate_cannot_be_resolved
    publish("0.1.0")
    publish("1.0.0.rc1")
    gemfile(%(gem "#{GEM}", "~> 1.0", "1.0.0.rc1"))

    scrub = ENV.keys.grep(/\A(BUNDLE_|BUNDLER_|RUBYOPT\z)/).to_h { |k| [k, nil] }
    out, status = Open3.capture2e(scrub.merge("BUNDLE_GEMFILE" => gemfile_path, "BUNDLE_APP_CONFIG" => File.join(@root, "config")),
                                  "bundle", "lock", chdir: @app)

    assert_not status.success?, "Bundler resolved a requirement nothing satisfies: #{out}"
    assert_match(/Could not find gem '#{GEM}/, out)
  end

  def test_a_pessimistic_pin_never_resolves_a_candidate_on_its_own
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)

    bundle("lock")
    assert_equal "0.1.0", locked, "the newest version in range is a prerelease, and Bundler must pass over it"

    bundle("lock", "--update", GEM, "--conservative")
    assert_equal "0.1.0", locked, "an explicit update of the gem still does not take the candidate"
  end

  # The other half of the lock-only rule, and why the ship reads the lock back:
  # with the final live, a plain `bundle lock` still keeps the candidate.
  def test_a_lock_keeps_the_candidate_until_the_gem_is_updated
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)
    bundle("lock")
    prepare_bump("0.2.0.rc1")
    publish("0.2.0")

    bundle("lock")

    assert_equal "0.2.0.rc1", locked
  end
end
