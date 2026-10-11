# frozen_string_literal: true

# [unit] CiGuardLanes: which whole-tree CI guards a diff selects for bin/fast-check,
# and the command each runs. The lanes themselves are driven in fast_check_test.rb.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/ci_guard_lanes"

class CiGuardLanesTest < Minitest::Test
  HUB = File.expand_path("../..", __dir__)

  def labels(changed, root: HUB) = CiGuardLanes.select(changed, root: root).map(&:label)

  def test_templates_components_and_helpers_select_the_template_ratchets
    %w[app/views/tasks/_card.html.erb app/components/badge_component.html.erb app/helpers/task_helper.rb
       test/views/inline_script_and_x_data_pins.yml].each do |path|
      assert_equal ["template-ratchets"], labels([path]), path
    end
  end

  def test_specs_and_the_playwright_contract_select_the_e2e_census
    %w[e2e/board.spec.js playwright.config.js config/e2e_lane.yml bin/lib/e2e_spec_census.rb
       bin/e2e-census-check].each do |path|
      assert_equal ["e2e-census"], labels([path]), path
    end
  end

  def test_a_diff_touching_neither_selects_nothing
    assert_empty labels(%w[app/models/task.rb docs/agents/index.md app/javascript/board.js])
  end

  def test_both_guards_in_declaration_order
    assert_equal %w[template-ratchets e2e-census], labels(%w[e2e/a.spec.js app/views/a.html.erb])
  end

  # A satellite desk carries none of the hub's guard files, so nothing is selected.
  def test_a_checkout_without_the_guard_files_selects_nothing
    Dir.mktmpdir do |root|
      assert_empty labels(%w[app/views/a.html.erb e2e/a.spec.js], root: root)
    end
  end

  def test_the_command_runs_the_scripts_then_the_tests
    census = CiGuardLanes::GUARDS.find { |g| g.label == "e2e-census" }
    ratchets = CiGuardLanes::GUARDS.find { |g| g.label == "template-ratchets" }

    assert_equal "bin/e2e-census-check && bin/rails test test/lib/e2e_quarantine_ratchet_test.rb",
                 CiGuardLanes.command(census, test_cmd: "bin/rails test")
    assert_equal "bin/rails test #{ratchets.tests.join(' ')}", CiGuardLanes.command(ratchets, test_cmd: "bin/rails test")
  end

  # Every file a guard names exists in the hub, so a rename cannot silently retire one.
  def test_every_guard_names_files_the_hub_carries
    CiGuardLanes::GUARDS.each do |guard|
      (guard.tests + guard.scripts).each { |path| assert File.exist?(File.join(HUB, path)), "#{guard.label}: #{path}" }
    end
  end
end
