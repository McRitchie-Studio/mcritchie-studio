# frozen_string_literal: true

# ToolchainEnv — rebuild the environment a child process would have seen BEFORE
# a Ruby toolchain manager rewrote it, so a script can boot an app that is NOT
# its own under that app's toolchain instead of under its own.
#
# ── WHY THIS IS A RESTORE AND NOT A LONGER DENY-LIST ────────────────────────
#
# bin/clean-artifacts boots every managed app to read its live logger. Those
# children used to inherit a hand-written scrub of SIX names — BUNDLE_GEMFILE,
# BUNDLE_PATH, BUNDLE_APP_CONFIG, RUBYOPT, RUBYLIB, BUNDLER_VERSION. PATH was
# not among them, and PATH was the one that mattered: bin/release execs the
# release runner as `mise x ruby@<version> -- ruby bin/release.rb`, and mise's
# ONLY environment change is prepending its Ruby bin dir to PATH. Measured
# 2026-09-22 by diffing a plain `env` against `mise x ruby@3.3.11 -- env`: PATH
# is the single substantive difference, and GEM_HOME, GEM_PATH, RUBYOPT and
# BUNDLE_GEMFILE are all EMPTY under `mise x` — so no gem-variable leak was ever
# involved, and the six-name scrub was a no-op in the lane that broke.
#
# Each audited app's `bin/rails` then resolved `ruby` through that PATH to
# mise's install rather than the toolchain its own bundle was installed under,
# and `require "bundler/setup"` failed at the app's config/boot.rb:3. On this
# machine both interpreters even report the SAME version (3.3.11) — homebrew's
# and mise's — so an app's .ruby-version cannot tell them apart. Only the gem
# tree differs, which is why the fix has to be the environment and not a
# version resolution.
#
# The damage ran BOTH ways, which is what makes a contaminated result worthless
# rather than merely pessimistic. Same command, same parameters, only the parent
# differing (measured 2026-09-22):
#
#   clean parent    moms-app LOOSE   · rolio LOOSE   · chain-ops LOOSE
#   under `mise x`  moms-app UNKNOWN · rolio UNKNOWN · chain-ops LOOSE
#
# Four genuinely loose apps hid inside UNKNOWN, leaving only chain-ops visible —
# and under a `bundle exec` parent an app measured healthy at a 16 MB cap read
# UNKNOWN too. So an UNKNOWN produced under a contaminated parent says nothing
# whatever about the app, in either direction.
#
# Adding PATH to those six names would have fixed this one symptom and left the
# mechanism intact, because THE ENUMERATION IS THE BUG: a list of names can only
# cover the variables somebody already thought of, so the next unlisted one gets
# found the same expensive way this one was. This module inverts the direction.
# It does not decide which variables are dangerous. It asks the toolchain
# managers what they changed, reading the records they write about THEMSELVES:
#
#   * Bundler's EnvironmentPreserver saves BUNDLER_ORIG_<KEY> for every key it
#     rewrites. The record NAMES ITS OWN VARIABLE, so restoring every
#     BUNDLER_ORIG_* pair restores every variable bundler touched — including
#     ones this file has never heard of. That is `Bundler.original_env`
#     semantics, reimplemented rather than required, because this runs in a
#     process that must not be bound to any bundle.
#   * mise records the PATH it replaced in __MISE_ORIG_PATH.
#
# The day bundler preserves a variable nobody here has named, it is restored
# with no edit to this file. That is the property the six-name list did not have.
module ToolchainEnv
  module_function

  # Bundler's EnvironmentPreserver contract.
  BUNDLER_PREFIX = "BUNDLER_ORIG_"

  # Bundler writes this exact string when the variable was UNSET before bundler
  # ran. Restoring it means DELETING the key — setting it to the sentinel hands
  # the child a RUBYOPT whose value is a sentence, and `ruby` then dies on it
  # before the app's boot begins. Both constants are pinned against bundler's
  # own in test/lib/toolchain_env_test.rb rather than trusted as typed here: the
  # first draft of this file guessed the spelling, and the guess cost a green
  # suite four red fixtures.
  BUNDLER_ABSENT = "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"

  # mise's own record of the PATH it replaced.
  MISE_ORIG_PATH = "__MISE_ORIG_PATH"

  # Bundler's whole configuration surface is the BUNDLE_ namespace: it reads
  # config from BUNDLE_<UPPERCASED_KEY>, so any project binding lives here.
  # Clearing the NAMESPACE — rather than three of its members, as the old scrub
  # did — keeps a binding from following the child without anyone maintaining a
  # list. BUNDLER_ORIG_* and BUNDLER_VERSION do not match it (`BUNDLER_` ≠
  # `BUNDLE_`), which is deliberate: the records must survive to be read.
  BUNDLE_NAMESPACE = /\ABUNDLE_/

  # The prior scrub's two non-BUNDLE_ names, plus bundler's version pin, kept
  # ONLY as a floor: they are cleared when no BUNDLER_ORIG_ record accounted for
  # them, so this module cannot lose coverage the six-name list already had.
  # This is NOT the mechanism and MUST NOT GROW. A newly discovered variable is
  # handled by the restoration above; that is precisely why PATH is absent here.
  RESIDUAL_KEYS = %w[RUBYOPT RUBYLIB BUNDLER_VERSION].freeze

  # Process.spawn-style overrides (String => String, or nil meaning "unset")
  # that turn `source` back into its pre-toolchain self.
  def child_overrides(source = ENV)
    env = source.to_h
    overrides = {}

    # 1. Restore everything the toolchain managers recorded about themselves.
    env.each do |key, value|
      next unless key.start_with?(BUNDLER_PREFIX)

      target = key[BUNDLER_PREFIX.length..].to_s
      next if target.empty?

      overrides[key] = nil # the record is consumed, not passed on
      overrides[target] = (value == BUNDLER_ABSENT ? nil : value)
    end

    # `mise activate` runs in the login shell, OUTSIDE any `bundle exec`, so its
    # record is the deeper of the two and wins PATH when both are present.
    mise_path = env[MISE_ORIG_PATH]
    unless mise_path.nil? || mise_path.empty?
      overrides["PATH"] = mise_path
      overrides[MISE_ORIG_PATH] = nil
    end

    # 2. Unbind the bundler namespace — whatever survived step 1, and whatever
    #    step 1 itself restored from a record.
    (env.keys | overrides.keys).each do |key|
      overrides[key] = nil if key.match?(BUNDLE_NAMESPACE)
    end

    # 3. Floor: clear the old scrub's remaining names when nothing restored them.
    RESIDUAL_KEYS.each { |key| overrides[key] = nil unless overrides.key?(key) }

    overrides
  end

  # `source` with the overrides applied — the environment the child actually
  # gets. Used for reporting and for tests that need to read a resolved value.
  def restored(source = ENV)
    env = source.to_h
    child_overrides(env).each { |key, value| value.nil? ? env.delete(key) : env[key] = value }
    env
  end

  # Which `ruby` a child spawned with these overrides will actually run.
  #
  # This is the ONE fact that separates a contaminated audit from a clean one —
  # the failure this module exists to end was invisible precisely because
  # nothing ever printed it — so the sweep reports it beside the audit.
  def resolved_ruby(source = ENV)
    restored(source)["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?

      candidate = File.join(dir, "ruby")
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end
end
