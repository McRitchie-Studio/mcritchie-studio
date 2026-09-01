# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require Rails.root.join("bin/lib/lint_waiver_guard").to_s

# LintWaiverGuard — the AUDIT half of the declared lint waiver.
#
# THE PROPERTY THIS FILE EXISTS FOR is that "absent toolchain" and "broken
# toolchain" stay two different things, which takes two opposite rules:
#
#   never inferred  a MISSING rubocop grants nothing (FullSuiteGate#lint_waived?,
#                   asserted in cert_lint_lane_waiver_test.rb and executed end-to-end
#                   in full_suite_check_test.rb). Broken can never read as absent.
#   always audited  a PRESENT toolchain revokes the declaration (this file). Absent
#                   can never quietly outlive the fact.
#
# So the direction is the thing to guard: this module may REVOKE a waiver and may
# never GRANT one. Most of what follows tries to make it grant something.
class LintWaiverGuardTest < ActiveSupport::TestCase
  # The two repos that actually declare `lint_lane: none`. Read from the registry
  # rather than hard-coded, so this file cannot drift out of step with it.
  WAIVED = "solana-studio"
  UNWAIVED = "turf-monster"

  def with_tree
    Dir.mktmpdir { |dir| yield dir }
  end

  test "the fixtures are what this file thinks they are" do
    # Guard the guard: every assertion below is vacuous if these two flip.
    assert FullSuiteGate.lint_waived?(WAIVED), "#{WAIVED} must declare lint_lane: none"
    assert_not FullSuiteGate.lint_waived?(UNWAIVED), "#{UNWAIVED} must NOT declare a waiver"
  end

  # --- the honest case ------------------------------------------------------

  test "a declared waiver over a tree with no toolchain is left alone" do
    with_tree do |dir|
      assert_nil LintWaiverGuard.refusal(repo: WAIVED, root: dir),
                 "the waiver's claim still holds, so nothing may be refused"
    end
  end

  # --- REVOKE: the declaration has stopped being true -----------------------

  test "each lint-toolchain marker revokes the waiver on its own" do
    markers = {
      ".rubocop.yml" => ->(dir) { File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n") },
      ".rubocop.yaml" => ->(dir) { File.write(File.join(dir, ".rubocop.yaml"), "AllCops:\n") },
      "bin/rubocop" => lambda { |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin/rubocop"), "#!/bin/sh\n")
      },
      "Gemfile" => ->(dir) { File.write(File.join(dir, "Gemfile"), %(source "x"\ngem "rubocop", "~> 1.0"\n)) },
      "the.gemspec" => lambda { |dir|
        File.write(File.join(dir, "the.gemspec"), %(Gem::Specification.new do |spec|\n  spec.add_development_dependency "rubocop-rails"\nend\n))
      }
    }

    markers.each do |label, write|
      with_tree do |dir|
        write.call(dir)
        refusal = LintWaiverGuard.refusal(repo: WAIVED, root: dir)

        assert refusal, "#{label} is a lint toolchain — the waiver must be revoked, not honoured"
        assert_includes refusal, label, "the refusal must name WHAT it found: #{refusal}"
        assert_includes refusal, "config/release_repos.yml",
                        "and where the DECLARATION is fixed, since the run is not what is wrong"
      end
    end
  end

  test "the refusal names the registry line as the repair, not the run" do
    with_tree do |dir|
      File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n")
      refusal = LintWaiverGuard.refusal(repo: WAIVED, root: dir)

      assert_includes refusal, "lint_lane: none", "it must quote the line to delete"
      assert_includes refusal, WAIVED, "and say whose row"
      assert_match(/NOTHING was certified/i, refusal,
                   "a refusal must say no evidence was produced, or it reads like a warning")
    end
  end

  # --- it may NEVER grant ---------------------------------------------------

  test "an unwaived repo is never refused, whatever its tree holds" do
    with_tree do |dir|
      File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n")

      assert_nil LintWaiverGuard.refusal(repo: UNWAIVED, root: dir),
                 "this guard has no opinion about a repo that declared nothing"
    end
  end

  # THE DIRECTION, stated as a property rather than a comment: for a repo that
  # declares NO waiver, an EMPTY tree — no rubocop anywhere, the exact shape that
  # would tempt an inference — must still produce nothing. If this module ever
  # learned to grant, this is the call that would start returning a waiver.
  test "a missing toolchain in an unwaived repo grants nothing" do
    with_tree do |dir|
      assert_nil LintWaiverGuard.refusal(repo: UNWAIVED, root: dir)
      assert_equal [], LintWaiverGuard.markers(dir)
      assert_not FullSuiteGate.lint_waived?(UNWAIVED),
                 "the absence of a toolchain must not have taught anything to waive it"
    end
  end

  test "the guard exposes no way to say yes" do
    # Structural, and the reason the module is separate from FullSuiteGate: its
    # public surface is a refusal, a hint and a marker list. None of them is a
    # waiver, so no caller can read a grant out of it even by mistake.
    surface = LintWaiverGuard.methods(false).sort

    assert_equal %i[markers matches? refusal undeclared_hint], surface,
                 "a new public method here is a new chance to grant a waiver from the environment"
  end

  # --- marker CALIBRATION ---------------------------------------------------

  test "a mention of rubocop is not a declaration of it" do
    with_tree do |dir|
      File.write(File.join(dir, "Gemfile"), <<~RUBY)
        source "https://rubygems.org"
        # gem "rubocop" — deliberately not enabled in this repo
        gem "rake"
      RUBY

      assert_equal [], LintWaiverGuard.markers(dir),
                   "a commented-out dependency is the repo saying NO — refusing on it would " \
                   "revoke a waiver the repo is entitled to"
    end
  end

  test "a transitive lock entry is not intent" do
    with_tree do |dir|
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          specs:
            rubocop (1.60.0)
      LOCK

      assert_equal [], LintWaiverGuard.markers(dir),
                   "the lock records what RESOLVED; only the Gemfile and gemspec record what was " \
                   "ASKED FOR, and intent is the question"
    end
  end

  test "an unreadable candidate is not a marker" do
    with_tree do |dir|
      # A DIRECTORY named .rubocop.yml is not a config file. The guard refuses a
      # cert, so it must never do so on something it could not actually read.
      FileUtils.mkdir_p(File.join(dir, ".rubocop.yml"))

      assert_equal [], LintWaiverGuard.markers(dir)
    end
  end

  # --- the undeclared hint --------------------------------------------------

  test "the hint offers the registry route only to a repo that has not taken it" do
    hint = LintWaiverGuard.undeclared_hint(UNWAIVED)

    assert hint, "a repo with no waiver and no rubocop needs to be told the route exists"
    assert_includes hint, "lint_lane: none"
    assert_match(/broken/i, hint,
                 "and told plainly that it is NOT for a rubocop the repo ships that merely broke")
    assert_nil LintWaiverGuard.undeclared_hint(WAIVED),
               "a waived repo already has its route — repeating it is noise"
  end
end
