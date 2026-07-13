# frozen_string_literal: true

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
  def self.system_tier?(cmd)
    cmd.to_s.include?("test:system")
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
