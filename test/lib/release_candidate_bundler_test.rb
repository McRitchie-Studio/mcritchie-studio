# frozen_string_literal: true

# How REAL Bundler treats a release candidate in a consumer's lock. Standalone:
#   ruby -Itest test/lib/release_candidate_bundler_test.rb
#
# bin/release prepare locks consumers to a prerelease (x.y.z.rc1) for QA and
# bin/release ship re-locks them to the final x.y.z. Both moves rest on one Bundler
# rule: a prerelease is resolved only when a requirement names one
# (Gem::Requirement#prerelease?, https://bundler.io/guides/rubygems.html and
# https://guides.rubygems.org/patterns/#prerelease-gems). This file runs the real
# `bundle lock` against a gem source on disk, so the rule is measured, not quoted.
#
# No network: the source is a file:// index this test writes, and the probe gem has
# no dependencies.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "zlib"
require "rubygems/package"
require_relative "../../app/models/release/gemfile_repin"

class ReleaseCandidateBundlerTest < Minitest::Test
  GEM = "pgaq-probe"
  R = Release::GemfileRepin

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
  def bundle(*args)
    env = ENV.keys.grep(/\A(BUNDLE_|RUBYOPT\z|RUBYLIB\z|GEM_HOME\z|GEM_PATH\z)/).to_h { |k| [k, nil] }
    env.merge!("BUNDLE_GEMFILE" => File.join(@app, "Gemfile"), "BUNDLE_APP_CONFIG" => File.join(@root, "config"),
               "BUNDLE_USER_HOME" => File.join(@root, "home"), "BUNDLE_FROZEN" => "false")
    out, status = Open3.capture2e(env, "bundle", *args, chdir: @app)
    assert_predicate status, :success?, "bundle #{args.join(' ')} failed:\n#{out}"
    out
  end

  def locked
    File.read(File.join(@app, "Gemfile.lock"))[/^    #{GEM} \(([^)]+)\)$/, 1]
  end

  PLAIN = %(gem "#{GEM}", "~> 0.1")

  def test_a_pessimistic_pin_never_resolves_a_candidate_on_its_own
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)

    bundle("lock")
    assert_equal "0.1.0", locked, "the newest version in range is a prerelease, and Bundler must pass over it"

    bundle("lock", "--update", GEM, "--conservative")
    assert_equal "0.1.0", locked, "an explicit update of the gem still does not take the candidate"
  end

  def test_the_exact_candidate_requirement_locks_the_candidate
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(PLAIN)
    bundle("lock")

    File.write(File.join(@app, "Gemfile"), R.pin_candidate(File.read(File.join(@app, "Gemfile")), GEM, "0.2.0.rc1"))
    bundle("lock", "--update", GEM, "--conservative")

    assert_equal "0.2.0.rc1", locked
  end

  # The ship: the final is live, the candidate requirement is dropped, the gem is
  # updated. Both steps are needed, and the two controls below say why.
  def test_dropping_the_candidate_and_updating_locks_the_final
    lock_the_candidate_then_publish_the_final
    File.write(File.join(@app, "Gemfile"), R.drop_candidate(File.read(File.join(@app, "Gemfile")), GEM))

    bundle("lock", "--update", GEM, "--conservative")

    assert_equal "0.2.0", locked
    assert_equal %(source "file://#{@repo}"\n#{PLAIN}\n), File.read(File.join(@app, "Gemfile"))
  end

  # CONTROL 1: with the candidate requirement still in the Gemfile, the final is
  # never taken, however it is asked for.
  def test_the_candidate_requirement_holds_the_lock_while_it_stands
    lock_the_candidate_then_publish_the_final

    bundle("lock", "--update", GEM, "--conservative")

    assert_equal "0.2.0.rc1", locked
  end

  # CONTROL 2: with the requirement dropped and NO update, Bundler keeps the
  # candidate: an in-range prerelease still satisfies "~> 0.1". So the ship reads
  # the lock back, and a lock on a prerelease is refused wherever one is found.
  def test_a_lock_keeps_the_candidate_after_the_requirement_is_dropped
    lock_the_candidate_then_publish_the_final
    File.write(File.join(@app, "Gemfile"), R.drop_candidate(File.read(File.join(@app, "Gemfile")), GEM))

    bundle("lock")

    assert_equal "0.2.0.rc1", locked
  end

  def lock_the_candidate_then_publish_the_final
    publish("0.1.0")
    publish("0.2.0.rc1")
    gemfile(%(gem "#{GEM}", "~> 0.1", "0.2.0.rc1"))
    bundle("lock")
    assert_equal "0.2.0.rc1", locked
    publish("0.2.0")
  end
end
