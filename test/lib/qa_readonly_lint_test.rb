# frozen_string_literal: true

# Standalone test for bin/lib/qa_readonly_lint — the @qa-readonly-vs-seed-fixture
# lint. The pure module cases run against synthetic specs; the final [integration]
# case asserts the REAL e2e/ tree is clean (the regression guard for the
# board_cleared_block false-red seal). Run directly:
#   ruby -Itest test/lib/qa_readonly_lint_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/qa_readonly_lint"

class QaReadonlyLintTest < Minitest::Test
  L = QaReadonlyLint

  E2E_DIR = File.expand_path("../../e2e", __dir__)

  # --- [unit] seed_slugs: every `slug: "..."` literal in e2e/seed.rb -----------

  def test_seed_slugs_extracts_every_slug_literal
    seed = <<~RUBY
      Task.create!(title: "X", slug: "e2e-cleared-block-demo", stage: "submitted")
      Task.create!(title: "Y", slug: 'timeline-demo')
      Agent.create!(name: "Alex", slug: "alex")
    RUBY
    slugs = L.seed_slugs(seed)
    assert_includes slugs, "e2e-cleared-block-demo"
    assert_includes slugs, "timeline-demo"
    assert_includes slugs, "alex"
  end

  def test_seed_slugs_dedupes
    assert_equal ["alex"], L.seed_slugs('slug: "alex"\nslug: "alex"')
  end

  # --- [unit] readonly_spec?: only a @qa-readonly TITLE counts ------------------

  def test_readonly_spec_detects_a_tagged_test_title
    assert L.readonly_spec?('test("renders the board @qa-readonly", async () => {})')
  end

  def test_readonly_spec_detects_a_tagged_describe_title
    assert L.readonly_spec?('test.describe("QA read-only smoke @qa-readonly", () => {})')
  end

  def test_readonly_spec_ignores_a_comment_mention
    # release_seal.spec.js documents @qa-readonly in a // comment — NOT a runnable
    # tag, so --grep never selects it and the lint must not treat it as readonly.
    spec = <<~JS
      // the verdict of the read-only @qa-readonly suite (bin/prod-smoke)
      test("release seal renders", async () => {});
    JS
    refute L.readonly_spec?(spec)
  end

  # --- [unit] fixture_references: pin forms match, structural/routes do not -----

  SLUGS = %w[e2e-cleared-block-demo timeline-demo alex].freeze

  def test_flags_a_board_card_selector
    assert_equal ["e2e-cleared-block-demo"],
                 L.fixture_references('page.locator("#card-e2e-cleared-block-demo")', SLUGS)
  end

  def test_flags_a_task_detail_path
    assert_equal ["timeline-demo"], L.fixture_references('page.goto("/tasks/timeline-demo")', SLUGS)
  end

  def test_flags_a_whole_quoted_slug_token
    assert_equal ["timeline-demo"], L.fixture_references("getByText('timeline-demo')", SLUGS)
  end

  def test_does_not_flag_a_route_segment_that_merely_contains_a_slug
    # /alex/pipeline references the alex ROUTE, not the alex fixture — a legitimately
    # @qa-readonly assertion. The `alex` slug must not match here (the real-world
    # false-positive that would wrongly demand dropping the tag from alex_pipeline).
    text = 'page.goto("/alex/pipeline"); page.locator("[data-test=\'alex-pipeline\']")'
    assert_empty L.fixture_references(text, SLUGS)
  end

  def test_does_not_flag_structural_ids_or_data_test_hooks
    text = 'page.locator("#col-actions"); page.locator("[data-test=\'pl-span\']")'
    assert_empty L.fixture_references(text, SLUGS)
  end

  # --- [unit] violations: only @qa-readonly specs are checked -------------------

  SEED = 'Task.create!(slug: "e2e-cleared-block-demo")'

  def test_violation_when_a_readonly_spec_pins_a_fixture
    specs = { "bad.spec.js" => 'test("x @qa-readonly", () => { page.locator("#card-e2e-cleared-block-demo"); })' }
    v = L.violations(specs, SEED)
    assert_equal 1, v.size
    assert_equal "bad.spec.js", v.first["spec"]
    assert_equal ["e2e-cleared-block-demo"], v.first["slugs"]
  end

  def test_no_violation_when_a_NON_readonly_spec_pins_a_fixture
    # A fixture-dependent spec is FINE as long as it is not @qa-readonly — it runs
    # in CI/full-suite against the seeded DB, just not in the prod seal.
    specs = { "ok.spec.js" => 'test("x", () => { page.locator("#card-e2e-cleared-block-demo"); })' }
    assert_empty L.violations(specs, SEED)
  end

  def test_no_violation_when_a_readonly_spec_is_structural_only
    specs = { "ok.spec.js" => 'test("x @qa-readonly", () => { page.locator("#col-actions"); })' }
    assert_empty L.violations(specs, SEED)
  end

  def test_message_names_spec_slug_and_the_fix
    v = [{ "spec" => "bad.spec.js", "slugs" => ["e2e-cleared-block-demo"] }]
    msg = L.message(v)
    assert_match(/bad\.spec\.js/, msg)
    assert_match(/e2e-cleared-block-demo/, msg)
    assert_match(/drop @qa-readonly/, msg)
  end

  # --- [integration] the REAL e2e/ tree must be clean --------------------------
  # The regression guard: this is what would have caught the board_cleared_block
  # false-red seal. Reads the actual e2e/seed.rb + every e2e/*.spec.js.

  def test_real_e2e_specs_have_no_readonly_seed_fixture_violations
    seed_text = File.read(File.join(E2E_DIR, "seed.rb"))
    specs = Dir.glob(File.join(E2E_DIR, "*.spec.js")).to_h { |path| [File.basename(path), File.read(path)] }
    refute_empty specs, "expected e2e/*.spec.js files to lint"

    violations = L.violations(specs, seed_text)
    assert_empty violations, L.message(violations)
  end
end
