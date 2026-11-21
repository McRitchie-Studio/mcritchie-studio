# frozen_string_literal: true

# Guard: the system lane installs a Chrome below 158. Chrome 158 rejects Capybara 3.40's
# teardown call (Storage.clearDataForOrigin, origin '*') as "* is not a valid URL", so a
# floating `stable` reddens every system test in all repos that call reusable-ci.yml.
# Lift the ceiling only in the PR that patches Capybara's reset! or bumps past the bug.
# History: task pin-ci-chrome-before-158.
require "minitest/autorun"
require "yaml"

class CiWorkflowChromePinTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/reusable-ci.yml", __dir__)
  FIRST_BROKEN_MAJOR = 158

  def chrome_steps
    jobs = YAML.load_file(WORKFLOW, aliases: true).fetch("jobs")
    jobs.values.flat_map { |job| job["steps"] || [] }
        .select { |step| step["uses"].to_s.start_with?("browser-actions/setup-chrome") }
  end

  def test_the_system_lane_installs_chrome
    refute_empty chrome_steps, "no setup-chrome step in #{WORKFLOW}: this guard is looking in the wrong place"
  end

  def test_every_chrome_install_pins_a_major_below_the_capybara_break
    chrome_steps.each do |step|
      version = step.dig("with", "chrome-version").to_s
      assert_match(/\A\d+\z/, version, "setup-chrome floats on #{version.inspect}; pin a major below #{FIRST_BROKEN_MAJOR}")
      assert_operator version.to_i, :<, FIRST_BROKEN_MAJOR,
                      "Chrome #{version} rejects Capybara 3.40's reset! (origin '*'); every system test errors in teardown"
    end
  end

  def test_the_pin_names_its_cause_and_its_exit
    text = File.read(WORKFLOW)
    assert_includes text, "pin-ci-chrome-before-158"
    assert_includes text, "Exit: drop the pin"
  end
end
