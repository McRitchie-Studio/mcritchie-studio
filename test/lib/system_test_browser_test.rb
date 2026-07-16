# frozen_string_literal: true

# [unit] tests for bin/lib/system_test_browser.rb — the headless-Chrome probe
# behind bin/full-suite-check's cert guard (a missing browser must not read as a
# red diff). Pure; the caller's abort WORDING is asserted in its own test
# (full_suite_check_test). (bin/release.rb's gate guard used this too until the
# local gate suite was deleted in DevOps v2 Phase 4 — GitHub CI is the gate now.)
# Run directly:
#   ruby -Itest test/lib/system_test_browser_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/system_test_browser"
require_relative "../../bin/lib/ci_test_command"

class SystemTestBrowserTest < Minitest::Test
  def test_system_tier_binds_only_commands_that_run_test_system
    # The guard must fire for CI's full suite and stay out of the way of the
    # integration subset — a browserless host still runs those lanes fine.
    assert SystemTestBrowser.system_tier?("bin/rails db:test:prepare test test:system")
    refute SystemTestBrowser.system_tier?("bin/rails test")
    refute SystemTestBrowser.system_tier?("bin/rails test test/integration")
    refute SystemTestBrowser.system_tier?(nil)
  end

  # --- the union: the guard must FAIL SAFE ---------------------------------------

  def test_the_guard_still_sees_the_tier_through_a_WRAPPER
    # THE REGRESSION. Unifying the guard on the command PARSER bought the PATH form
    # (`bin/rails test test/system`) and LOST every WRAPPER form: the parser asks
    # whether a RAILS invocation is handed the tier, and in `docker compose run web
    # bin/rails test:system` the executable is `docker`. #518's substring probe caught
    # these. The guard takes BOTH now — a browser guard does not get to be clever:
    # over-firing costs an "install Chrome" message; UNDER-firing runs the tier
    # browserless, where Selenium dies INSIDE the suite and reads as a RED SUITE —
    # at the release gate, that EJECTS A GOOD PR at the last gate before production.
    [
      "docker compose run web bin/rails test:system",
      "docker compose run --rm web bundle exec rails db:test:prepare test:system",
      "timeout 30m bin/rails db:test:prepare test test:system",
      "ssh ci-host 'cd /app && bin/rails test:system'",
      "bin/with-env test bin/rails test:system",
    ].each do |cmd|
      assert SystemTestBrowser.system_tier?(cmd),
             "the browser guard went BLIND on a wrapper form: #{cmd}"
    end
  end

  def test_the_union_keeps_BOTH_halves
    # The two halves catch different things, and neither alone is enough.
    assert SystemTestBrowser.system_tier?("bin/rails test test/system"),
           "the PATH form — caught only by the STRUCTURAL half"
    refute CiTestCommand.system_tier?("docker compose run web bin/rails test:system"),
           "the structural half does NOT see wrapper forms — which is why the union exists"
    assert SystemTestBrowser.system_tier?("docker compose run web bin/rails test:system"),
           "the wrapper form — caught only by the TEXTUAL half"
  end

  def test_the_union_covers_the_WRAPPER_and_PATH_intersection
    # The one form BOTH halves miss on their own: the executable is docker (so the
    # STRUCTURAL half sees no rails invocation) AND there is no literal `test:system`
    # (so a `test:system`-only TEXTUAL half sees nothing either). It still runs the
    # tier — and an under-firing browser guard ejects a GOOD PR at the last gate before
    # prod. Both textual spellings, or this hole stays open.
    cmd = "docker compose run web bin/rails test test/system"
    refute CiTestCommand.system_tier?(cmd), "structurally invisible: the exe is docker"
    refute cmd.include?("test:system"), "…and it carries no literal `test:system`"
    assert SystemTestBrowser.system_tier?(cmd),
           "the guard must still demand a browser: this command DOES drive Chrome"
  end

  def test_the_union_does_not_over_fire_on_the_integration_subset
    # Over-firing is the CHEAP error, but it is still an error: a satellite whose
    # gate command runs the integration subset must not demand Chrome on the host.
    refute SystemTestBrowser.system_tier?("bin/rails test test/integration test/models")
    refute SystemTestBrowser.system_tier?("docker compose run web bin/rails test")
    refute SystemTestBrowser.system_tier?("bin/rails db:test:prepare")
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
