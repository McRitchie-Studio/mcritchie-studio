# frozen_string_literal: true

require_relative "ci_test_command"

# SystemTestBrowser — the shared headless-Chrome probe behind every system-tier
# guard.
#
# System tests drive a real headless Chrome. On a host with no Chrome, Selenium
# fails INSIDE the suite: the runner exits non-zero with a driver error, which
# looks EXACTLY like a red suite. Read that way, it misattributes an ENV problem
# to the code —
#   * at the release gate (bin/release.rb): eject/revert guidance for a perfectly
#     good PR, at the last gate before an irreversible prod deploy;
#   * at the builder's cert (bin/full-suite-check): a builder sent hunting a
#     phantom bug in their own diff.
# Both callers therefore assert the browser UP FRONT and abort in the ENV class,
# with wording that names it as such. This module is the detection they share; the
# ABORT WORDING stays with each caller (their consequences differ).
#
# Only bind the guard to commands that actually run the tier (`system_tier?`), so
# an integration-subset lane never demands a browser on the host.
#
# Chrome, NOT chromedriver: there is deliberately no driver on PATH — like
# ci.yml, we let Selenium Manager fetch the chromedriver MATCHED to the installed
# Chrome (a stale driver on PATH is PREFERRED by Selenium Manager and then fails
# on a major-version skew).
module SystemTestBrowser
  CHROME_BINARIES = %w[google-chrome google-chrome-stable chromium chromium-browser chrome].freeze
  MACOS_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  # TEST SEAM. "1" forces the probe to say present, "0" to say absent — so both
  # guards are assertable on ANY host (this suite runs on a Mac with Chrome and on
  # CI's browserless-until-setup Linux runner, and the verdict must be the same).
  # Unset in real use; setting it to "1" to skip the guard only buys you the red
  # suite the guard exists to explain.
  ENV_OVERRIDE = "MCR_SYSTEM_TEST_BROWSER"
  # Test-only override for the macOS Chrome.app path (the probe's one absolute path).
  MACOS_ENV_OVERRIDE = "MCR_SYSTEM_TEST_MACOS_CHROME"

  INSTALL_HINT = "Install Chrome (macOS: `brew install --cask google-chrome`; Linux: install " \
                 "google-chrome/chromium), then re-run. Do NOT install a chromedriver — Selenium " \
                 "Manager fetches the one matching your Chrome."

  # Does this command run the SYSTEM tier (and therefore need a browser)?
  #
  # A UNION of two probes, because a browser guard must FAIL SAFE:
  #
  #   * STRUCTURAL (bin/lib/ci_test_command.rb) — parse the command and ask whether a
  #     RAILS invocation is handed the tier. This is what catches the PATH form,
  #     `bin/rails test test/system`, which a substring scan misses entirely.
  #   * TEXTUAL — does the command text mention the tier at all (`test:system`, or the
  #     path form `test/system`). This is what catches every WRAPPER form, which the
  #     parser misses entirely: in `docker compose run web bin/rails test:system`, `ssh
  #     host 'bin/rails test:system'` or `timeout 30m bin/rails test:system`, the
  #     EXECUTABLE is not rails, so the structural probe reads it as "no rails
  #     invocation" and says false.
  #
  # BOTH textual spellings, because their INTERSECTION is a real command that BOTH
  # halves miss: `docker compose run web bin/rails test test/system` is structurally
  # invisible (the exe is docker) AND carries no literal `test:system`. One probe per
  # spelling of the tier is what the asymmetry below demands.
  #
  # Unifying the guard on the parser alone (the shared-probe refactor) bought the path
  # form and QUIETLY TRADED AWAY the wrapper forms the textual probe had covered since
  # the guard was written. Keep BOTH: the two probes miss different things, and the
  # cost of their two errors is nowhere near symmetric —
  #   * OVER-firing costs an "install Chrome" message on a host that did not need one;
  #   * UNDER-firing runs the system tier with NO BROWSER, where Selenium fails INSIDE
  #     the suite and reads exactly like a RED SUITE — at the release gate that EJECTS
  #     A GOOD PR at the last gate before production, and at the cert it sends a
  #     builder hunting a phantom bug in their own diff.
  # A guard whose two failure modes cost that differently does not get to be clever.
  # The parser's own `system_tier?` stays EXACT (it answers "what tier does this
  # command run?"); the SAFE union belongs here, with the guard.
  def self.system_tier?(cmd)
    CiTestCommand.system_tier?(cmd) || CiTestCommand::SUITE_MARKERS.any? { |marker| cmd.to_s.include?(marker) }
  end

  def self.available?(env = ENV)
    forced = env[ENV_OVERRIDE].to_s.strip
    return forced == "1" unless forced.empty?

    macos = env.fetch(MACOS_ENV_OVERRIDE, MACOS_CHROME)
    File.executable?(macos) || CHROME_BINARIES.any? { |bin| executable_on_path?(bin, env) }
  end

  # Pure PATH scan (no subprocess): does an executable by this name exist?
  def self.executable_on_path?(name, env = ENV)
    env.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      next false if dir.empty?

      File.executable?(File.join(dir, name))
    end
  end
end
