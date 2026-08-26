# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require_relative "../../lib/boot_gem_diagnosis"

# [unit] + [integration] for the boot-time release diagnosis.
#
# The bug: `bin/release ship` publishes a gem and fast-forwards main by REF PUSH,
# installing nothing locally. Once a primary's tree catches up, every Rails-booting
# script there dies at config/boot.rb with a Bundler trace that names no cause, in
# a command unrelated to deploys. Two reviewers lost time to it on 2026-08-26 and
# neither diagnosed it.
class BootGemDiagnosisTest < ActiveSupport::TestCase
  REAL_MESSAGE = "Could not find studio-engine-0.61.1 in locally installed gems"

  # ---- unit ---------------------------------------------------------------

  test "the missing gem and version are read out of Bundler's message" do
    assert_equal({ name: "studio-engine", version: "0.61.1" },
                 BootGemDiagnosis.missing_gem(REAL_MESSAGE))
  end

  test "a hyphenated gem name keeps its hyphens and loses only the version" do
    assert_equal({ name: "activerecord-postgis-adapter", version: "9.0.2" },
                 BootGemDiagnosis.missing_gem(
                   "Could not find activerecord-postgis-adapter-9.0.2 in locally installed gems"
                 ))
  end

  # nil means "say the general thing", never "guess". A wrong gem name in a
  # diagnostic is worse than no gem name.
  test "an unrecognised message yields nil rather than a guess" do
    assert_nil BootGemDiagnosis.missing_gem("Bundler::VersionConflict: something else entirely")
  end

  test "the explanation names the gem, the cause and the exact fix" do
    text = BootGemDiagnosis.explain(REAL_MESSAGE, root: "/Users/alex/projects/mcritchie-studio")

    assert_includes text, "studio-engine-0.61.1"
    assert_includes text, "RELEASE"
    assert_includes text, "REF PUSH", "the explanation must say WHY nothing was installed locally"
    assert_includes text, "(cd /Users/alex/projects/mcritchie-studio && bundle install)"
  end

  test "an unparseable message still explains itself without printing nil" do
    text = BootGemDiagnosis.explain("Bundler::VersionConflict: nope", root: "/tmp/x")

    assert_includes text, "bundle install"
    refute_includes text, "nil", "the fallback leaked a nil into operator-facing text"
    refute_includes text, "-()", "the fallback rendered an empty gem name"
  end

  # ---- integration --------------------------------------------------------
  #
  # Runs the REAL config/boot.rb in a REAL subprocess against a REAL Bundler,
  # made to fail by pointing BUNDLE_GEMFILE at a Gemfile whose lock pins a
  # version that is not installed. That is precisely the shape a release leaves
  # behind, so the error class, message and timing are the genuine article rather
  # than a stub's imitation.
  #
  # An earlier cut of this test stubbed `bundler/setup` on the load path instead.
  # It reported GREEN while the real Bundler loaded ahead of the stub and boot
  # SUCCEEDED — the test proved nothing. Kept as a note because the failure was
  # invisible until the exit status was asserted.
  #
  # RUBYOPT is cleared so the parent's own `-rbundler/setup` cannot fire before
  # boot.rb's begin block and bypass the rescue under test.
  # WHY THREE VARIABLES AND NOT JUST RUBYOPT. A bundler-managed parent (this test
  # suite is one) exports BUNDLER_SETUP and RUBYLIB as well. With those inherited,
  # RubyGems activates the bundle from `gem_prelude` at INTERPRETER STARTUP, so a
  # missing gem raises BEFORE config/boot.rb's first line and the rescue never
  # runs. The first cut of this test cleared only RUBYOPT and failed with a
  # backtrace ending in `<internal:gem_prelude>` — which is not a test artifact
  # but a REAL limitation of boot-time rescues, pinned by its own test below.
  CLEAN_ENV = { "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "RUBYLIB" => nil }.freeze

  def boot_with_gemfile(gemfile_body, lock_body = nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), gemfile_body)
      File.write(File.join(dir, "Gemfile.lock"), lock_body) if lock_body

      Open3.capture2e(
        CLEAN_ENV.merge("BUNDLE_GEMFILE" => File.join(dir, "Gemfile")),
        RbConfig.ruby, Rails.root.join("config/boot.rb").to_s
      )
    end
  end

  MISSING_GEMFILE = <<~GEMFILE
    source "https://rubygems.org"
    gem "studio-engine", "99.99.99"
  GEMFILE

  MISSING_LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        studio-engine (99.99.99)

    PLATFORMS
      ruby

    DEPENDENCIES
      studio-engine (= 99.99.99)

    BUNDLED WITH
       2.5.23
  LOCK

  test "a gem the lock pins but the machine lacks prints the release diagnosis" do
    out, status = boot_with_gemfile(MISSING_GEMFILE, MISSING_LOCK)

    refute status.success?,
           "boot must still FAIL — the diagnosis explains the error, it must never swallow it"
    assert_includes out, "This looks like a RELEASE"
    assert_includes out, "studio-engine-99.99.99", "the diagnosis must name the gem Bundler could not find"
    assert_includes out, "bundle install"
    assert_includes out, "Could not find studio-engine-99.99.99",
                     "the ORIGINAL Bundler error must survive; the diagnosis is added, not substituted"
  end

  # THE SAFETY PROPERTY. The rescue is deliberately narrow: a boot failure that is
  # NOT a missing gem must come through untouched, with no invented explanation.
  test "an unrelated boot failure is re-raised with no diagnosis attached" do
    out, status = boot_with_gemfile("this is not valid ruby at all <<<\n")

    refute status.success?
    refute_includes out, "This looks like a RELEASE",
                     "an unrelated boot failure was mislabelled as a release problem"
  end

  # A healthy boot must be untouched: the rescue may not change or cost the
  # normal path, which every command in this repo pays on every run.
  test "a healthy boot runs straight through the rescue" do
    out, status = Open3.capture2e(
      CLEAN_ENV.merge("BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s),
      RbConfig.ruby, Rails.root.join("config/boot.rb").to_s
    )

    assert status.success?, "the happy path broke: #{out}"
    refute_includes out, "This looks like a RELEASE"
  end

  # THE KNOWN LIMIT, pinned so nobody credits this with coverage it does not have.
  #
  # When the bundle is activated BEFORE the script starts — a parent process that
  # exports `-rbundler/setup` in RUBYOPT, which every bundler-managed process does
  # to its children — RubyGems raises the missing gem at interpreter startup, and
  # config/boot.rb never executes. No rescue placed in boot.rb can reach that
  # case; it would need a wrapper around the interpreter itself.
  #
  # This is NOT the path the bug was reported on: an agent running `bin/reviewer-
  # select` from a normal shell boots through config/boot.rb and DOES get the
  # diagnosis (the test above). Recorded because the difference is invisible from
  # the outside — the same command explains itself from one shell and not another.
  test "a bundle activated before boot bypasses the rescue — known and pinned" do
    out, status = Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), MISSING_GEMFILE)
      File.write(File.join(dir, "Gemfile.lock"), MISSING_LOCK)
      Open3.capture2e(
        CLEAN_ENV.merge("BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
                        "RUBYOPT" => "-rbundler/setup"),
        RbConfig.ruby, Rails.root.join("config/boot.rb").to_s
      )
    end

    refute status.success?, "the missing gem must still fail the process"
    assert_includes out, "Could not find studio-engine-99.99.99"
    refute_includes out, "This looks like a RELEASE",
                     "if this now PASSES, the rescue reached a case it could not before — " \
                     "that is good news, and this test should be rewritten to assert the new coverage"
  end
end
