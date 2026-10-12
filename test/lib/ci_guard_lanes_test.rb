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

  def guard(label) = CiGuardLanes::GUARDS.find { |g| g.label == label }

  def test_templates_components_and_helpers_select_the_template_ratchets
    %w[app/views/tasks/_card.html.erb app/components/badge_component.html.erb app/helpers/task_helper.rb
       test/views/inline_script_and_x_data_pins.yml].each do |path|
      assert_equal %w[template-ratchets repo-ratchets], labels([path]), path
    end
  end

  def test_specs_and_the_playwright_contract_select_the_e2e_census
    %w[e2e/board.spec.js playwright.config.js config/e2e_lane.yml bin/lib/e2e_spec_census.rb
       bin/e2e-census-check].each do |path|
      assert_equal %w[e2e-census repo-ratchets], labels([path]), path
    end
  end

  # The whole-repo ratchets read every file, so any change selects them (a model, a
  # doc, a script, a config row) and nothing else is selected for a diff that touches
  # no template or spec.
  def test_any_change_selects_the_repo_ratchets_and_only_them
    %w[app/models/task.rb docs/agents/index.md app/javascript/board.js bin/task config/apps.yml].each do |path|
      assert_equal ["repo-ratchets"], labels([path]), path
    end
  end

  def test_an_empty_diff_selects_nothing
    assert_empty labels([])
  end

  def test_the_guards_in_declaration_order
    assert_equal %w[template-ratchets e2e-census repo-ratchets], labels(%w[e2e/a.spec.js app/views/a.html.erb])
  end

  # A satellite desk carries none of the hub's guard files, so none of them is selected.
  def test_a_checkout_without_the_guard_files_selects_nothing
    Dir.mktmpdir do |root|
      assert_empty labels(%w[app/views/a.html.erb e2e/a.spec.js], root: root)
    end
  end

  # A turf-monster desk carries turf's two ratchets and none of the hub's, so it gets
  # its own and only its own.
  def test_a_turf_checkout_selects_the_turf_ratchets_and_not_the_hubs
    Dir.mktmpdir do |root|
      guard("turf-ratchets").tests.each do |path|
        FileUtils.mkdir_p(File.join(root, File.dirname(path)))
        File.write(File.join(root, path), "")
      end
      assert_equal ["turf-ratchets"], labels(%w[app/models/contest.rb], root: root)
    end
  end

  def test_the_command_runs_the_scripts_then_the_tests
    assert_equal "bin/e2e-census-check && bin/rails test test/lib/e2e_quarantine_ratchet_test.rb",
                 CiGuardLanes.command(guard("e2e-census"), test_cmd: "bin/rails test")
    ratchets = guard("template-ratchets")
    assert_equal "bin/rails test #{ratchets.tests.join(' ')}", CiGuardLanes.command(ratchets, test_cmd: "bin/rails test")
  end

  # Every file a hub guard names exists in the hub, so a rename cannot silently retire
  # one. turf-ratchets names turf files, which CI (a hub-only checkout) cannot see; a
  # rename there leaves the guard unselected in turf, not red here.
  def test_every_guard_names_files_the_hub_carries
    CiGuardLanes::GUARDS.reject { |g| g.label == "turf-ratchets" }.each do |g|
      (g.tests + g.scripts).each { |path| assert File.exist?(File.join(HUB, path)), "#{g.label}: #{path}" }
    end
  end
end
