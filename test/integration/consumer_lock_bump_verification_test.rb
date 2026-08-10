require "test_helper"

# Integration: the consumer lock-bump verification reads REAL Bundler output.
#
# `Release::ShipSequence.lock_bump_landed?` is what `bin/release` now asserts
# before it commits a consumer's Gemfile.lock onto origin/release (and again
# before the ship's re-pin). Its unit tests use a handcrafted lockfile, which
# proves the parser against the shape we IMAGINED Bundler emits. This tier runs
# it against the shape Bundler ACTUALLY emits — this repo's own committed
# Gemfile.lock — with `Bundler.locked_gems` as the oracle and EVERY spec in the
# file as the population, so a future Bundler that changes indentation,
# ordering, or the spec layout turns this red instead of silently making the
# guard unable to find a version (which would abort every gem release).
#
# THE REGRESSION BEHIND IT (rel-20260809-3b8f3d, 2026-08-09): bin/release
# inferred "the lock is already at the published version" from an UNCHANGED
# working tree. A RubyGems index that had not propagated yet produces that same
# unchanged tree with the OLD version still resolved, so the sweep reported
# studio-engine 0.31.0 over a 0.30.0 lock and turf-monster rode QA on the wrong
# gem. The fix reads the lock; this test proves it can.
class ConsumerLockBumpVerificationTest < ActionDispatch::IntegrationTest
  LOCKFILE = Rails.root.join("Gemfile.lock").freeze

  def lock_text
    @lock_text ||= File.read(LOCKFILE)
  end

  # The value we compare against is derived from Bundler's own resolution, NOT
  # re-parsed with a second copy of the regex under test.
  def bundler_resolved_version(gem_name)
    spec = Bundler.locked_gems.specs.find { |s| s.name == gem_name }
    spec&.version&.to_s
  end

  # THE WHOLE LOCKFILE, not a flattering sample. An earlier version of this test
  # asserted two hand-picked pure-Ruby gems and claimed to prove the parser
  # against "the shape Bundler ACTUALLY emits". Generalising the oracle to every
  # spec is what surfaced the real defect: native gems get ONE SPEC ROW PER
  # PLATFORM with the platform inside the parens — `ffi (1.17.4-aarch64-linux-gnu)`
  # — so the parser was returning the platform suffix as part of the version and
  # disagreeing with Bundler on 4 gems (ffi, nokogiri, pg, tailwindcss-ruby)
  # across 12 rows. Sampling hid it; the population found it.
  test "[integration] locked_version agrees with Bundler on EVERY spec in the real lockfile" do
    specs = Bundler.locked_gems.specs
    assert_operator specs.size, :>, 100, "precondition: a real, fully populated lockfile"

    disagreements = specs.filter_map do |spec|
      mine = Release::ShipSequence.locked_version(lock_text, spec.name)
      next if mine == spec.version.to_s

      "#{spec.name}: bundler=#{spec.version} parser=#{mine.inspect}"
    end.uniq

    assert_empty disagreements,
                 "the parser must agree with Bundler for every resolved gem, including " \
                 "platform-specific rows:\n  #{disagreements.join("\n  ")}"
  end

  # The population test above would still pass if the lockfile happened to carry
  # no native gems, so pin that this repo really does exercise the suffix path.
  test "[integration] the lockfile really does contain platform-suffixed spec rows" do
    assert_match(/^ {4}\S+ \([^()]*-[a-z0-9_]+-[a-z]+/, lock_text,
                 "precondition: at least one native gem row carries a platform suffix, " \
                 "otherwise the agreement test above proves nothing about them")
  end

  # rails is nested as a dependency of several other specs AND listed in
  # DEPENDENCIES, so it exercises the multi-depth case on genuine output rather
  # than on a fixture built to contain it.
  test "[integration] locked_version picks the resolution when the gem also appears as a dependency" do
    assert_includes lock_text, "      rails (", "precondition: rails appears as a nested dependency"

    assert_equal bundler_resolved_version("rails"),
                 Release::ShipSequence.locked_version(lock_text, "rails"),
                 "a gem named at several depths still resolves to its GEM/specs version"
  end

  test "[integration] lock_bump_landed? accepts the version really in the lock" do
    live = bundler_resolved_version("studio-engine")
    assert Release::ShipSequence.lock_bump_landed?(lock_text, "studio-engine", live)
  end

  # The live failure, reproduced against real output: ask for a version the lock
  # does NOT carry and the guard must refuse, no matter how clean the tree is.
  test "[integration] lock_bump_landed? REFUSES a version the real lock does not resolve" do
    live = Gem::Version.new(bundler_resolved_version("studio-engine"))
    unpublished = "#{live.segments[0]}.#{live.segments[1].to_i + 99}.0"

    assert_not Release::ShipSequence.lock_bump_landed?(lock_text, "studio-engine", unpublished),
               "this is the propagation-lag case: bundle exits 0, the tree is clean, " \
               "and the lock still resolves the OLD version — the guard must say NO"
  end

  test "[integration] lock_bump_landed? refuses a gem the lock does not carry at all" do
    assert_nil Release::ShipSequence.locked_version(lock_text, "a-gem-that-does-not-exist")
    assert_not Release::ShipSequence.lock_bump_landed?(lock_text, "a-gem-that-does-not-exist", "1.0.0")
  end
end
