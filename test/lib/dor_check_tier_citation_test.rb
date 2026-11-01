# frozen_string_literal: true

# [unit, integration] A `cited_tiers` tier is credited by a test path, not the tag alone.
#   ruby -Itest test/lib/dor_check_tier_citation_test.rb
require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"
require_relative "../support/session_env"
require_relative "../../bin/lib/dor/checks"
require_relative "../../bin/lib/dor/check_context"
require_relative "../../bin/lib/dor/checks/tier_citation"

class DorCheckTierCitationTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  UNIT = "[unit] bin/rails test test/models/upload_test.rb"
  COMPONENT = "[component] existing test/components/upload_partial_test.rb:12"
  INTEGRATION = "[integration] test/integration/upload_flow_test.rb"
  E2E = "[e2e] npx playwright test e2e/upload.spec.js"
  CITED = [UNIT, COMPONENT, INTEGRATION, E2E].freeze

  def run_check(checks, shape: "ui+db", changed: [], root: Dir.pwd)
    devops = { "shape" => shape, "checks_run" => checks }
    context = Dor::Checks::Context.new(gate: "merge", gate_role: "submit", task: {}, devops: devops, slug: "t",
                                       diff_root: root, diff_base: "HEAD", pr_url: "", changed_files: changed)
    Dor::Checks::TierCitation.new.call(context)
    context
  end

  # ── [unit] each tier, each way to answer it ─────────────────────────────────

  def test_every_tier_cited_passes
    assert_empty run_check(CITED).errors
  end

  %w[unit component integration e2e].each_with_index do |tier, index|
    define_method("test_#{tier}_tag_with_prose_is_refused") do
      checks = CITED.dup
      checks[index] = "[#{tier}] looked at it, works"
      errors = run_check(checks).errors

      assert_equal 1, errors.size, errors.inspect
      assert_match(/\[#{tier}\] line .* names no test/, errors.first)
    end
  end

  def test_a_second_line_can_carry_the_citation
    assert_empty run_check(CITED + ["[unit] and by hand"]).errors
  end

  # The tag has to tell the truth about its lane.
  def test_an_e2e_tag_cannot_cite_a_rails_test
    checks = CITED[0..2] + ["[e2e] test/integration/upload_flow_test.rb"]

    assert_match(/\[e2e\] line/, run_check(checks).errors.first)
  end

  SYSTEM = "[e2e] test/system/upload_test.rb"

  def test_a_system_test_answers_e2e_only_with_no_playwright_config
    Dir.mktmpdir do |root|
      assert_empty run_check(CITED[0..2] + [SYSTEM], root: root).errors, "no Playwright: the lane there is"
    end
  end

  %w[playwright.config.js playwright.config.ts].each do |config|
    define_method("test_#{config.tr(".", "_")}_means_a_system_test_does_not_answer_e2e") do
      Dir.mktmpdir do |root|
        File.write(File.join(root, config), "")
        errors = run_check(CITED[0..2] + [SYSTEM], root: root).errors

        assert_match(/\[e2e\] line .*this repo has Playwright/, errors.first)
        assert_empty run_check(CITED, root: root).errors, "a spec still answers it"
      end
    end
  end

  def test_an_unreadable_root_holds_the_stricter_form
    assert_match(/\[e2e\] line/, run_check(CITED[0..2] + [SYSTEM], root: "/no/such/root").errors.first)
  end

  def test_a_path_inside_a_longer_word_is_not_a_citation
    assert_match(/\[unit\] line/, run_check(["[unit] latest/foo.rb"]).errors.first)
  end

  def test_a_missing_tier_is_left_to_the_tier_gate
    assert_empty run_check([UNIT]).errors
  end

  def test_a_shape_without_cited_tiers_keeps_the_tag_rule
    assert_empty run_check(["[unit] prose", "[integration] prose"], shape: "backend").errors
  end

  # ── [unit] a path this tree cannot see advises and never refuses ─────────────

  def test_an_unfound_path_suggests_and_does_not_refuse
    context = run_check(CITED)

    assert_empty context.errors
    assert_equal 4, context.suggestions.size
  end

  def test_a_path_in_the_diff_or_on_disk_is_found
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test/integration"))
      File.write(File.join(root, "test/integration/upload_flow_test.rb"), "")
      FileUtils.mkdir_p(File.join(root, "test/components"))
      File.write(File.join(root, "test/components/upload_partial_test.rb"), "")

      context = run_check(CITED, changed: ["test/models/upload_test.rb", "e2e/upload.spec.js"], root: root)
      assert_empty context.suggestions, "the :line suffix must not hide a real file"
    end
  end

  def test_the_refusal_states_both_halves_of_the_bar
    message = run_check(["[unit] prose"]).errors.first

    assert_match(/New logic at this tier: a test that goes red/, message)
    assert_match(/No new logic: the test covering the surface/, message)
  end

  # ── [integration] the real gate reads the real config ───────────────────────

  def test_the_shipped_ui_db_shape_demands_a_citation_for_all_four_tiers
    shapes = YAML.safe_load_file(File.expand_path("../../config/feature_shapes.yml", __dir__), aliases: true)["shapes"]

    assert_equal shapes["ui+db"]["dor_tiers"].sort, shapes["ui+db"]["cited_tiers"].sort,
                 "every tier stays demanded: citation changes how a tier is credited, never whether"
  end

  def test_the_real_gate_refuses_a_tag_and_credits_a_citation
    tag_only = dor_check(%w[unit component integration e2e].map { |tier| "[#{tier}] done" })
    assert_equal false, tag_only["ready"], tag_only.inspect
    assert_equal 4, tag_only["errors"].grep(/names no test/).size, tag_only["errors"].inspect

    cited = dor_check(CITED)
    assert_equal true, cited["ready"], cited.inspect
  end

  private

  def dor_check(checks)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      devops = { "shape" => "ui+db", "kind" => "feature", "repositories" => ["mcritchie-studio"], "risk_tags" => ["ui"],
                 "acceptance" => ["x"], "test_plan" => ["[unit] y"], "local_url" => "http://localhost:3000/x",
                 "checks_run" => checks }
      File.write(path, JSON.generate("slug" => "t", "title" => "T", "stage" => "building", "metadata" => { "devops" => devops }))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => "app/views/x.html.erb", "DOR_CHECK_PR_FILES" => "app/views/x.html.erb",
        "DOR_CHECK_PR_MIGRATIONS" => "", "DOR_CHECK_SIBLING_PRS" => "[]", "DOR_CHECK_CI_STATUS" => "green"
      )
      JSON.parse(IO.popen(env, [BIN, "--file", path, "--json"], err: File::NULL, &:read))
    end
  end
end
