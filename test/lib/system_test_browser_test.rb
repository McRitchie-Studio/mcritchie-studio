# frozen_string_literal: true

# [unit] tests for bin/lib/system_test_browser.rb — the shared headless-Chrome
# probe behind BOTH system-tier guards: bin/release.rb's gate guard (a missing
# browser must not read as a red release) and bin/full-suite-check's cert guard
# (a missing browser must not read as a red diff). Pure; the callers' abort
# WORDING is asserted in their own tests (release_cli_test / full_suite_check_test).
# Run directly:
#   ruby -Itest test/lib/system_test_browser_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/system_test_browser"

class SystemTestBrowserTest < Minitest::Test
  def test_system_tier_binds_only_commands_that_run_test_system
    # The guard must fire for CI's full suite and stay out of the way of the
    # integration subset — a browserless host still runs those lanes fine.
    assert SystemTestBrowser.system_tier?("bin/rails db:test:prepare test test:system")
    refute SystemTestBrowser.system_tier?("bin/rails test")
    refute SystemTestBrowser.system_tier?("bin/rails test test/integration")
    refute SystemTestBrowser.system_tier?(nil)
  end

  def test_available_is_forced_by_the_test_seam
    # The seam exists so BOTH guards are assertable on any host: this suite runs on
    # a Mac with Chrome AND on CI's Linux runner, and the verdict must be the same.
    assert SystemTestBrowser.available?({ SystemTestBrowser::ENV_OVERRIDE => "1" })
    refute SystemTestBrowser.available?({ SystemTestBrowser::ENV_OVERRIDE => "0" })
  end

  def test_available_probes_the_PATH_when_the_seam_is_unset
    Dir.mktmpdir do |dir|
      chrome = File.join(dir, "google-chrome")
      File.write(chrome, "#!/bin/sh\n")
      FileUtils.chmod("+x", chrome)

      assert SystemTestBrowser.available?({ "PATH" => dir, "HOME" => dir }),
             "an executable chrome on PATH must satisfy the probe"
      refute SystemTestBrowser.available?({ "PATH" => File.join(dir, "empty"), "HOME" => dir,
                                           SystemTestBrowser::MACOS_ENV_OVERRIDE => File.join(dir, "nope") }),
             "an empty PATH with no macOS Chrome must fail the probe"
    end
  end

  def test_the_install_hint_never_tells_anyone_to_install_a_chromedriver
    # Selenium Manager fetches the driver MATCHED to the installed Chrome; a
    # stale driver on PATH is PREFERRED by Selenium Manager and then fails on a
    # major-version skew (the exact trap ci.yml's `install-chromedriver: false`
    # + driver eviction exists to avoid).
    assert_includes SystemTestBrowser::INSTALL_HINT, "brew install --cask google-chrome"
    assert_includes SystemTestBrowser::INSTALL_HINT, "Do NOT install a chromedriver"
  end
end
